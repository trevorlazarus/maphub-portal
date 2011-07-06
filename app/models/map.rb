class Map < ActiveRecord::Base
  
  belongs_to :user, :counter_cache => true
  has_many :annotations
  has_and_belongs_to_many :collections
  
  def thumbnail_url
    return "#{tileset_url}/TileGroup0/0-0-0.jpg"
  end
  
end
