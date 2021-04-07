require "http/server"
require "option_parser"
require "html"

INITIAL_COORDINATES = {49.273251, -123.103767}
LATITUDE_RANGE      = (-90..90)
LONGITUDE_RANGE     = (-180..180)

SUN_SIZE_RANGE = (0.01..500.0)

# all sizes are in meters
ACTUAL_SUN_SIZE = 1_392_700_000

# astronomical units to meters
AU_TO_M = 147_000_000_000


# tuples of (Name, AstronomicalUnits, CelestialBodyRadius)
PLANETS = [
  {"Sun", 0, ACTUAL_SUN_SIZE},
  {"Mercury", 0.38, 4_878_000},
  {"Venus", 0.72, 12_104_000},
  {"Earth", 1, 12_756_000},
  {"Mars", 1.5, 6_794_000},
  {"Jupiter", 5.2, 142_984_000},
  {"Saturn", 9.5, 120_536_000},
  {"Uranus", 19.2, 51_118_000},
  {"Neptune", 30.1, 49_532_000},
]

alias LatLng = Tuple(Float64, Float64)

struct Placemark
  property coordinates
  property name : String
  property body_radius : Float64
  property orbit_distance : Float64

  def initialize(@name : String, @body_radius : Float64, @orbit_distance : Float64, @coordinates : Array(LatLng))
  end
end

def m_to_human(m : Float64 | Int32 )
  if m == 0.0
    "0m"
  elsif m >= 1000
    "#{(m / 1000.0).round(2)}km"
  elsif m.round(1) < 1
    # we'll often round to 0.99999999999 meters for the sun which looks silly
    # so we check for the post-rounded value before displaying millimeters
    "#{(m * 1000.0).round(1)}mm"
  else
    "#{(m * 1.0).round(1)}m"
  end
end

def circle_coordinates(orbit_radius, points = 100) : Array(LatLng)
  (0..points).map do |n|
    angle = n.to_f / points * 2.0 * Math::PI
    {
      orbit_radius * Math.cos(angle),
      orbit_radius * Math.sin(angle),
    }
  end
end

def radians(degrees)
  degrees * Math::PI / 180
end

EARTH_RADIUS = 6378137.0

# https://gis.stackexchange.com/questions/2951/algorithm-for-offsetting-a-latitude-longitude-by-some-amount-of-meters
def offset(lat_long : LatLng, x_y_in_meters : LatLng) : LatLng
  lat, long = lat_long
  x, y = x_y_in_meters
  {
    lat + y / (111111.0 * Math.cos(radians(long))),
    long + x / 111111.0,
  }
end

def build_placemark(centre_lat_long : LatLng, name : String, orbit_distance : Float64, body_radius : Float64)
  puts "Build placemark: #{centre_lat_long} -> #{name} orbit radius is #{orbit_distance}"
  inverted = {centre_lat_long[1], centre_lat_long[0]}
  coordinates = circle_coordinates(orbit_distance).map { |x_y| offset(inverted, x_y) }
  placemark = Placemark.new(name: name, coordinates: coordinates, body_radius: body_radius, orbit_distance: orbit_distance)
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

def generate_kml(sun_size : Float64, centre_lat_long : LatLng, placemarks : Array(Placemark) ) : String
  kml_circles = placemarks.map do |placemark|
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

  xml.strip
end

port = 8080

OptionParser.parse do |opts|
  opts.on("-p PORT", "--port PORT", "define port to run server") do |opt|
    port = opt.to_i
  end
end

GMAP_API_KEY = ENV["GMAP_API_KEY"]

server = HTTP::Server.new do |context|
  params = context.request.query_params
  sun_size = params.fetch("sun_size", "5").to_f
  raise "Sun value out of range" unless SUN_SIZE_RANGE.includes?(sun_size)

  latitude = params.fetch("latitude", INITIAL_COORDINATES[0].to_s).to_f
  raise "Latitude out of range" unless LATITUDE_RANGE.includes?(latitude)

  longitude = params.fetch("longitude", INITIAL_COORDINATES[1].to_s).to_f
  raise "Longitude out of range" unless LONGITUDE_RANGE.includes?(longitude)

  kml_endpoint = "http://#{context.request.host_with_port}/kml?sun_size=#{sun_size}&latitude=#{latitude}&longitude=#{longitude}&s=#{Time.utc.to_unix}"
  puts "Endpoint: #{kml_endpoint}"

  ratio = sun_size / ACTUAL_SUN_SIZE
  puts "Calculating for sun size of #{sun_size}m... - ratio: #{ratio}"

  centre_lat_long = {latitude, longitude}

  placemarks = PLANETS.map do |planet|
    name, distance_in_au, actual_body_radius = planet[0], planet[1], planet[2]
    scaled_orbit_radius = distance_in_au * ratio * AU_TO_M
    scaled_body_radius = actual_body_radius * ratio

    build_placemark(centre_lat_long, name, scaled_orbit_radius, scaled_body_radius)
  end

  if context.request.path == "/kml"
    context.response.content_type = "text/xml"
    context.response.print generate_kml(sun_size, centre_lat_long, placemarks)
  else
    context.response.content_type = "text/html"
    context.response.print generate_html(sun_size, centre_lat_long, kml_endpoint, placemarks)
  end
end

address = server.bind_tcp "0.0.0.0", port
puts "Listening on http://#{address}"

server.listen

def generate_html(sun_size, initial_coordinates : LatLng, kml_endpoint : String, placemarks : Array(Placemark))
  data_rows = String.build do |str|
    placemarks.each do |p|
      str << "<tr><th>#{p.name}</th><td class='num'>#{m_to_human(p.body_radius)}</td><td class='num'>#{m_to_human(p.orbit_distance)}</td></th>"
    end
  end

  html = <<-HTML
  <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Anywhere Solar System</title>
        <style>
          body { margin: 8px; background: #bfbfbf; font: 14px serif; }
          #map { width: 400px; height: 400px; margin: 1rem 0; border: 2px solid #fff; }
          table { margin: 1rem 0; }
          th, td { padding: 0.25rem 1rem; text-align: left; }
          tbody th, tbody td { border-top: 1px solid #ccc; }
          table .num { text-align: right; }
        </style>
        <script>
          var map;
          var kmlLayer;
          var src = '#{HTML.escape(kml_endpoint)}';

          function initMap() {
            map = new google.maps.Map(document.getElementById('map'), {
              center: new google.maps.LatLng(#{initial_coordinates[0]}, #{initial_coordinates[1]}),
              zoom: 2,
              mapTypeId: 'terrain'
            });

            map.setZoom(7);


            kmlLayer = new google.maps.KmlLayer(src, { preserveViewport: false, map: map });
          }
        </script>
      </head>
      <body>
        <h1>Make your own local Solar System</h1>

        <p>Just like the <a href="http://www.swedensolarsystem.se/en/">Sweden Solar System</a></p>

        <form method="get" action="/">
          <label>Sun size (in meters)
            <input type="number" name="sun_size" id="sun_size" value="#{sun_size}" min="#{SUN_SIZE_RANGE.begin}" max="#{SUN_SIZE_RANGE.end}" step="0.01">
          <br>
          <label>Sun latitude
            <input type="text" name="latitude" id="latitude" value="#{initial_coordinates[0]}">
          </label>
          <br>
          <label>Sun longitude
            <input type="text" name="longitude" id="longitude" value="#{initial_coordinates[1]}">
          </label>
          <br>
          <input type="submit">
        </form>

        <br>
        <button id="geolocate">Use my current location</button>

        <div id="map"></div>

        <table>
          <thead><tr><th>Body</th><th class='num'>Size</th><th class='num'>Distance from Centre</th></tr></thead>
          <tbody>#{data_rows}</tbody>
        </table>

        <p>Lifted and crystalized from <a href="https://github.com/pcreux/science-world-solar-system">github.com/pcreux/science-world-solar-system</a></p>
        <p>Source code at <a href="https://github.com/alexdunae/anywhere-solar-system">github.com/alexdunae/anywhere-solar-system</a></p>

        <script async defer src="https://maps.googleapis.com/maps/api/js?key=#{GMAP_API_KEY}&callback=initMap"></script>
        <script>
        function geolocate(event) {
            event.preventDefault();
            function success(position) {
              document.getElementById('latitude').value = position.coords.latitude;
              document.getElementById('longitude').value = position.coords.longitude;
            }

            if(!navigator.geolocation) {
              alert('Geolocation is not supported by your browser');
            } else {
              status.textContent = 'Locating…';
              navigator.geolocation.getCurrentPosition(success, function () {
                  alert('Unable to retrieve your location');
              });
            }
          }

          document.querySelector('#geolocate').addEventListener('click', geolocate);
        </script>
      </body>
    </html>
  HTML

  html.strip
end
