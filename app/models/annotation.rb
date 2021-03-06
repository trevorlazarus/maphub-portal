require 'open-uri'
require 'net/http'
require 'timeout'

class Annotation < ActiveRecord::Base
  
  # Validation
  validates_presence_of :body, :map
  
  # Hooks
  after_save :enrich_tags, :update_map
  after_destroy :update_map
  
  # Model associations
  belongs_to :user, :counter_cache => true
  belongs_to :map
  has_one :boundary, :as => :boundary_object
  accepts_nested_attributes_for :boundary
  has_many :tags, :dependent => :destroy
    
  # Virtual attributes
  
  def google_maps_annotation
    if map.control_points.count >= 3
      gmaps_annotation = GoogleMapsAnnotation.new
      gmaps_annotation.to_latlng(wkt_data, map.control_points.first(3))
     else
      ""
    end
  end
  
  def truncated_body
    (body.length > 30) ? body[0, 30] + "..." : body
  end
  
  def update_map
    logger.debug("Informing parent about new annotation.")
    map.touch
    map.index
  end
  
  # Enrich the associated tags with all available DBPedia labels
  def enrich_tags
    tags.each do |tag|
      if tag.accepted?
        enrichment = Annotation.fetch_enrichment(tag.dbpedia_uri) 
        if enrichment.length > 0
          logger.debug("Enriching tag: #{tag.dbpedia_uri}")
          tag.update_attribute(:enrichment, enrichment)
          tag.save!
        end
      end
    end
    # Reindex the map
    logger.debug("Reindexing the map")
  end
  
  # Finds tags for given input text
  def self.find_tags_from_text(text)
    tags = []
    
    return tags if text.length < 5
    
    query = Rails.configuration.wikipedia_miner_uri + "/services/wikify?"
    query << "source=#{URI::encode(text)}"
    query << "&minProbability=0.1"
    query << "&disambiguationPolicy=loose"
    query << "&responseFormat=json"
    
    logger.debug("Executing Wikify query: " + query)
    
    begin
      url = URI.parse(query)
      response = nil
      begin
        status = Timeout::timeout(Rails.configuration.remote_timeout) {
          response = Net::HTTP.get_response(url)
        }
      rescue Timeout::Error
        logger.warn("Fetching text-based tags timed out after #{Rails.configuration.remote_timeout} seconds.")
        return tags
      end
      if response.code == "200"
        response = ActiveSupport::JSON.decode response.body
        response["detectedTopics"].each do |entry|
          title = entry["title"]
          dbpedia_uri = "http://dbpedia.org/resource/" + 
                          entry["title"].gsub(" ", "_")
          # Try to fetch abstrac from DBPedia
          abstract_text = fetch_abstract(dbpedia_uri)
          tag = {
            label: title,
            dbpedia_uri: dbpedia_uri,
            description: abstract_text
          }
          tags << tag
        end # each response entry
      end # if response is found
    rescue
      logger.warn("Failed to fetch text-based tags for query #{query}")
    end
    tags
  end
  
  # Creates a DBPedia SPARQL request URI from a given sparql query
  def self.create_dbpedia_sparql_request_uri(sparql_query)
    uri = Rails.configuration.dbpedia_sparql_uri + ""
    uri << URI.encode_www_form("default-graph-uri" => 
                                          "http://dbpedia.org")
    uri << "&" + URI.encode_www_form("query" => sparql_query)
    uri << "&" + URI.encode_www_form("format" => 
                                            "application/sparql-results+json")
    uri << "&" + URI.encode_www_form("timeout" => "0")
    uri << "&" + URI.encode_www_form("debug" => "on")
  end
  
  # Fetches enrichments (= label translations) for a given DBPedia resource
  def self.fetch_enrichment(dbpedia_uri)
    
    enrichments = []
    
    sparql_query = <<-eos
      select ?label
      where {
        <#{dbpedia_uri}> <http://www.w3.org/2000/01/rdf-schema#label> ?label .
      }
    eos
    
    query_uri = create_dbpedia_sparql_request_uri(sparql_query)
    
    logger.debug("Executing SPARQL query: " + query_uri)
    
    begin
      request_uri = URI.parse(query_uri)
      response_abstract = nil
      begin
        status = Timeout::timeout(Rails.configuration.remote_timeout) {
          response_abstract = Net::HTTP.get_response(request_uri)
        }
      rescue Timeout::Error
        logger.warn("Fetching enrichments timed out after #{Rails.configuration.remote_timeout} seconds.")
        return enrichments
      end
    
      if not response_abstract.nil? and response_abstract.code == "200"
        response_abstract = ActiveSupport::JSON.decode response_abstract.body
        bindings = response_abstract["results"]["bindings"]
        bindings.each do |binding|
          enrichments << binding["label"]["value"]
        end
      end
      return enrichments.uniq.join(" ")
    rescue
      logger.warn("Could not fetch abstract from #{dbpedia_uri}.")
      return enrichments
    end
  end
  
  
  # Fetches the abstract for a given DBPedia resource
  def self.fetch_abstract(dbpedia_uri)
    
    abstract_text = "Abstract could not be found."
    
    sparql_query = <<-eos
      select ?abstract
      where {
        <#{dbpedia_uri}> <http://dbpedia.org/ontology/abstract> ?abstract .
        FILTER ( lang(?abstract) = "en" )
      }
    eos
    
    query_uri = create_dbpedia_sparql_request_uri(sparql_query)
    
    logger.debug("Executing SPARQL query: " + query_uri)
    
    begin
      request_uri = URI.parse(query_uri)
      response_abstract = nil
      begin
        status = Timeout::timeout(Rails.configuration.remote_timeout) {
          response_abstract = Net::HTTP.get_response(request_uri)
        }
      rescue Timeout::Error
        logger.warn("Fetching abstract timed out after #{Rails.configuration.remote_timeout} seconds.")
        return abstract_text
      end
      
      if response_abstract.code == "200"
        response_abstract = ActiveSupport::JSON.decode response_abstract.body
        bindings = response_abstract["results"]["bindings"][0]
        abstract = bindings["abstract"]["value"]
        abstract_text = abstract[0...294] + " (...)"
      end
    rescue
      logger.warn("Could not fetch abstract from #{dbpedia_uri}.")
    end
    abstract_text
  end
  
  # Finds matching nearby Wikipedia articles for the location
  def self.find_tags_from_boundary(map, boundary)
    tags = []
    # if there are more than two control points, we have the boundaries for this map
    if map.control_points.count > 2
      
      cp = map.control_points.first(3)  # => TODO, maybe don't just blindly take the first three ones?
      
      # get the edges of the boundary box
      north, east = ControlPoint.compute_latlng_from_known_xy(boundary.ne_x, boundary.ne_y, cp)
      south, west = ControlPoint.compute_latlng_from_known_xy(boundary.sw_x, boundary.sw_y, cp)
      
      params = { north: north, west: west, east: east, south: south }

      # compose query
      query = Rails.configuration.geoname_query + ""
      params.each do |key, val|
        query << "#{key}=#{val.to_f}&"
      end
      
      # add username, we kinda need this, TODO: get our own?
      query << "maxRows=5&"
      query << Rails.configuration.geoname_user
      logger.debug "Executing GeoNames query: #{query}"
            
      # parse response
      begin
        url = URI.parse(query)
        response = nil
      
        begin
          status = Timeout::timeout(Rails.configuration.remote_timeout) {
            response = Net::HTTP.get_response(url)
          }
        rescue Timeout::Error
          logger.warn("Fetching boundary-based tags timed out after #{Rails.configuration.remote_timeout} seconds.")
          return tags
        end
      
        if not response.nil? and response.code == "200"
          response = ActiveSupport::JSON.decode response.body
          response["geonames"].each do |entry|
            tag = {
              label: entry["title"],
              dbpedia_uri: "http://" +
                  entry["wikipediaUrl"].gsub("en.wikipedia.org/wiki/",
                                              "dbpedia.org/resource/"),
              description: entry["summary"]
            }
            tags << tag
          end
        end
      rescue
        logger.warn("Failed to fetch boundary-based tags for query #{query}")
      end
    end
    tags
  end

  ##### Open Annotation Serialization methods #######

  # Creates a segment object from WKT data
  def segment
    Segment.create_from_wkt_data(self.wkt_data)
  end
  
  # Writes annotation metadata in a given RDF serialization format
  def to_rdf(format, options = {})
    
    httpURI = options[:httpURI] ||= "http://example.com/missingBaseURI"
    host = options[:host] ||= "http://maphub.info"
    
    # Defining the custom vocabulary # TODO: move this to separate lib
    oa_uri = RDF::URI('http://www.w3.org/ns/openannotation/core/')
    oa = RDF::Vocabulary.new(oa_uri)
    oax_uri = RDF::URI('http://www.w3.org/ns/openannotation/extensions/')
    oax = RDF::Vocabulary.new(oax_uri) 
    ct_uri = RDF::URI('http://www.w3.org/2011/content#')
    ct = RDF::Vocabulary.new(ct_uri)
    foaf_uri = RDF::URI('http://xmlns.com/foaf/spec/')
    foaf = RDF::Vocabulary.new(foaf_uri)    
    
    # Building the annotation graph
    baseURI = RDF::URI.new(httpURI)
    graph = RDF::Graph.new
    graph << [baseURI, RDF.type, oa.Annotation]
    unless self.created_at.nil?
      graph << [
        baseURI,
        oa.annotated, 
        RDF::Literal.new(self.created_at, :datatype => RDF::XSD::dateTime)]
    end
    unless self.updated_at.nil?
      graph << [
        baseURI,
        oa.generated, 
        RDF::Literal.new(self.updated_at, :datatype => RDF::XSD::dateTime)]
    end
    graph << [baseURI, oa.generator, RDF::URI(host)]
    
    # Adding user and provenance data
    user_uuid = UUIDTools::UUID.timestamp_create().to_s
    user_node = RDF::URI.new(user_uuid)
    graph << [baseURI, oa.annotator, user_node]
    graph << [user_node, foaf.mbox, RDF::Literal.new(self.user.email)]
    graph << [user_node, foaf.name, RDF::Literal.new(self.user.username)]
    
    # Adding semantic tags
    tags.each do |tag|
      if tag.accepted?
        semantic_tag = RDF::URI.new(tag.dbpedia_uri)
        graph << [baseURI, oax.hasSemanticTag, semantic_tag]
      end
    end
    
    # Creating the body
    unless self.body.nil?
      body_uuid = UUIDTools::UUID.timestamp_create().to_s
      body_node = RDF::URI.new(body_uuid)
      graph << [baseURI, oa.hasBody, body_node]
      graph << [body_node, RDF.type, ct.ContentAsText]
      graph << [body_node, ct.chars, self.body]
      graph << [body_node, RDF::DC.format, "text/plain"]
    end
    
    # Creating the target
    unless self.map.nil?
      # the specific target
      specific_target_uuid = UUIDTools::UUID.timestamp_create().to_s
      specific_target = RDF::URI.new(specific_target_uuid)
      graph << [baseURI, oa.hasTarget, specific_target]
      graph << [specific_target, RDF.type, oa.SpecificResource]
      
      # the SVG selector
      svg_selector_uuid = UUIDTools::UUID.timestamp_create().to_s
      svg_selector_node = RDF::URI.new(svg_selector_uuid)
      graph << [specific_target, oa.hasSelector, svg_selector_node]
      graph << [svg_selector_node, RDF.type, ct.ContentAsText]
      graph << [svg_selector_node, RDF::DC.format, "image/svg"]
      graph << [svg_selector_node,
                  ct.chars,
                  self.segment.to_svg(self.map.width, self.map.height)]
      
      # the WKT selector
      wkt_selector_uuid = UUIDTools::UUID.timestamp_create().to_s
      wkt_selector_node = RDF::URI.new(wkt_selector_uuid)
      graph << [specific_target, oa.hasSelector, wkt_selector_node]
      graph << [wkt_selector_node, RDF.type, ct.ContentAsText]
      graph << [wkt_selector_node, RDF::DC.format, "application/wkt"]
      graph << [wkt_selector_node, ct.chars, self.wkt_data]

      # the target source
      graph << [specific_target, oa.hasSource, self.map.raw_image_uri]
    end
    
    # Serializing RDF graph to string
    RDF::Writer.for(format.to_sym).buffer do |writer|
      writer.prefix :dcterms, RDF::URI('http://purl.org/dc/terms/')
      writer.prefix :oa, oa_uri
      writer.prefix :ct, ct_uri
      writer.prefix :rdf, RDF::URI(RDF.to_uri)
      writer.prefix :foaf, foaf_uri
      writer.prefix :oax, oax_uri
      writer << graph
    end
    
  end

end

class GoogleMapsAnnotation
  #Takes a POLYGON or LINESTRING shape and 3 control points from a map
  #and outputs a formatted string with the lat/lng coordinates of the
  #shape
  def to_latlng(shape, cp)
    latlngcoordinates = ""
    if shape.start_with?("POLYGON")
      coordinates = shape["POLYGON".length+2..-3]
    elsif shape.start_with?("LINESTRING")
      coordinates = shape["LINESTRING".length+1..-2]
    end
    coordinates.split(",").each do |point_pair|
      coord = point_pair.split(" ")
      x = coord[0].to_f 
      y = coord[1].to_f
      lat, lng = ControlPoint.compute_latlng_from_known_xy(x, y, cp)
      latlngcoordinates << lat.to_s + " " + lng.to_s + ","
    end
    return latlngcoordinates[0..-2] #gets rid of trailing comma
  end
end 

# TODO: this should defenitely go to a separate class
class Segment
  
  def self.create_from_wkt_data(wkt_data)
    if wkt_data.start_with?("POLYGON")
      return Polygon.create_from_wkt_data(wkt_data)
    elsif wkt_data.start_with?("LINESTRING")
      return Linestring.create_from_wkt_data(wkt_data)
    elsif wkt_data.start_with?("POINT")
      return Point.create_from_wkt_data
    else
      raise "Unnown Segment shape: #{wkt_data}"
    end
    
  end
  
  def to_svg(width, height)
    # TODO: add namespace
    %{
    <?xml version="1.0" standalone="no"?>
         #{svg_shape}
    }
  end

end


class Point < Segment
  
  attr_reader :x, :y
  
  def initialize(x,y)
    @x = x
    @y = y
  end
  
  def self.create_from_wkt_data(wkt_data)
    data = wkt_data["POINT".length+1..-2]
    xy = data.split(" ")
    Point.new(xy[0], xy[1])
  end
  
  def to_s
    "#{@x},#{@y}"
  end
    
end

class Linestring < Segment

  attr_reader :points
  
  def initialize(points)
    @points = points
  end
  
  def self.create_from_wkt_data(wkt_data)
    points = []
    data = wkt_data["LINESTRING".length+1..-2]
    data.split(",").each do |point_pair|
      point = Point.create_from_wkt_data("POINT(#{point_pair})")
      points << point
    end
    Linestring.new(points)
  end
  
  def to_s
    @points.join(" ")
  end
    
  def svg_shape
    %{<polyline xmlns="http://www.w3.org/2000/svg"
              points="#{to_s}" />
    }
  end


end


class Polygon < Linestring
  
  def self.create_from_wkt_data(wkt_data)
    points = []
    data = wkt_data["POLYGON".length+2..-3]
    data.split(",").each do |point_pair|
      point = Point.create_from_wkt_data("POINT(#{point_pair})")
      points << point
    end
    Polygon.new(points)
  end

  def svg_shape
    %{<polygon xmlns="http://www.w3.org/2000/svg"
              points="#{to_s}" />
    }
  end
  
end




