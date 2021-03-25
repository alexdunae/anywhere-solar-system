require "http/server"
require "option_parser"
require "html"

port = 8080

OptionParser.parse do |opts|
  opts.on("-p PORT", "--port PORT", "define port to run server") do |opt|
    port = opt.to_i
  end
end

GMAP_API_KEY = ENV["GMAP_API_KEY"]

INITIAL_COORDINATES = {-123.103767, 49.273251}

# all sizes are in meters
SUN_SIZE = 1_392_700_000

# tuples of (Name, OrbitRadius, CelestialBodyRadius)
PLANETS = [
  {"Sun", 0, SUN_SIZE},
  {"Mercury", 57_900_000_000,  4_878_000},
  {"Venus", 108_160_000_000, 12_104_000},
  {"Earth", 149_600_000_000, 12_756_000},
  {"Mars",  227_936_640_000, 6_794_000},
  {"Jupiter", 778_369_000_000, 142_984_000},
  {"Saturn",  1_427_034_000_000, 120_536_000},
  {"Uranus",  2_870_658_186_000, 51_118_000},
  {"Neptune", 4_496_976_000_000, 49_532_000}
]

alias LatLng = Tuple(Float64, Float64)

struct Placemark
  property coordinates
  property name : String
  property body_radius : Float64

  def initialize(@name : String, @body_radius : Float64, @coordinates : Array(LatLng))
  end
end


def circle_coordinates(orbit_radius, points = 100): Array(LatLng)
  (0..points).map do |n|
    angle = n.to_f / points * 2.0 * Math::PI
    {
      orbit_radius * Math.cos(angle),
      orbit_radius * Math.sin(angle)
    }
  end
end

def radians(degrees)
  degrees * Math::PI / 180
end

# https://gis.stackexchange.com/questions/2951/algorithm-for-offsetting-a-latitude-longitude-by-some-amount-of-meters
def offset(lat_long : LatLng, x_y_in_meters : LatLng) : LatLng
  lat, long = lat_long
  x, y = x_y_in_meters
  {
    lat + y / (111111.0 * Math.cos(radians(long))),
    long + x / 111111.0
  }
end

def build_placemark(name, orbit_radius, body_radius)
  coordinates = circle_coordinates(orbit_radius).map { |x_y| offset(INITIAL_COORDINATES, x_y) }
  placemark =  Placemark.new(name: name, coordinates: coordinates, body_radius: body_radius)
end

def kml_circle(placemark : Placemark)
  <<-XML
    <Placemark>
      <name>#{placemark.name}</name>
      <description>#{placemark.name} body radius is #{placemark.body_radius}m</description>
      <visibility>1</visibility>
      <Style>
        <geomColor>ff0000ff</geomColor>
        <geomScale>1</geomScale>
      </Style>
      <LineString>
        <coordinates>
          #{placemark.coordinates.map { |c| [c[0], c[1], 0].join(',') }.join(' ')}
        </coordinates>
      </LineString>
    </Placemark>
  XML
end

def generate_kml(sun_size : Float64) : String
  ratio = sun_size / SUN_SIZE
  puts "Calculating for sun size of #{sun_size}m... - ratio: #{ratio}"

  kml_circles = PLANETS.map do |planet|
    name, actual_orbit_radius, actual_body_radius = planet[0], planet[1], planet[2]
    scaled_orbit_radius = actual_orbit_radius * ratio
    scaled_body_radius = actual_body_radius * ratio
    placemark = build_placemark(name, scaled_orbit_radius, scaled_body_radius)
    kml_circle(placemark)
  end

  xml = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <kml xmlns="http://www.opengis.net/kml/2.2">
    <Folder>
      <name>Anywhere Solar System</name>
      <visibility>1</visibility>
      #{kml_circles.join("\n")}
    </Folder>
  </kml>
  XML

  xml.chomp.strip
end

server = HTTP::Server.new do |context|
  params = context.request.query_params
  raw_input = params.fetch("sun_size", "5")
  sun_size = raw_input.chomp.to_f / 1.0
  raise "Sun value out of range" if sun_size <= 0 || sun_size > 100_000


  kml_endpoint = "http://#{context.request.host_with_port}/kml?sun_size=#{sun_size}"


  if context.request.path == "/kml"
    context.response.content_type = "text/xml"
    context.response.print generate_kml(sun_size)
  else
    context.response.content_type = "text/html"
    context.response.print generate_html(sun_size, kml_endpoint)
  end
end

address = server.bind_tcp "0.0.0.0", port
puts "Listening on http://#{address}"

server.listen


def generate_html(sun_size, kml_endpoint)
  html = <<-HTML
  <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Anywhere Solar System</title>
        <style>
          body { margin: 8px; background: #bfbfbf; font: 14px serif; }
          #map { width: 400px; height: 400px; margin: 1rem 0; border: 2px solid #fff; }
        </style>
        <script>
          var map;
          var src = '#{HTML.escape(kml_endpoint)}';

          function initMap() {
            map = new google.maps.Map(document.getElementById('map'), {
              center: new google.maps.LatLng(#{INITIAL_COORDINATES[1]}, #{INITIAL_COORDINATES[0]}),
              zoom: 2,
              mapTypeId: 'terrain'
            });


            var kmlLayer = new google.maps.KmlLayer(src, {
              preserveViewport: false,
              map: map
            });
          }
        </script>
      </head>
      <body>
        <form method="get" action="/">
          <label for="sun_size">Sun size (in meters)</label>
          <input type="number" name="sun_size" id="sun_size" value="#{sun_size}" min="0" max="100000">
          <input type="submit">
        </form>

        <div id="map"></div>
        <p>Lifted and crystalized from <a href="https://github.com/pcreux/science-world-solar-system">pcreux/science-world-solar-system</a></p>


        <script async defer src="https://maps.googleapis.com/maps/api/js?key=#{GMAP_API_KEY}&callback=initMap"></script>

      </body>
    </html>
  HTML

  html.chomp.strip
end
