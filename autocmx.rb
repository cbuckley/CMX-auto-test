require "rubygems"
require "sinatra"
require "sequel"
require "rack-flash"
require "sinatra/redirect_with_flash"
require "json"
require "yaml"
require "rack-google-analytics"
require "logger"

enable :sessions

use Rack::Flash, :sweep => true
CONFIG = YAML.load_file("config.yml") unless defined? CONFIG

SITE_TITLE = "CMX Testing"
SITE_DESCRIPTION = "Automated CMX test server"
SECRET = CONFIG['secret']
HOSTNAME = CONFIG['hostname']
PORT = CONFIG['port']

# Create a log file instead of just printing to output
log = Logger.new(CONFIG['log_file'],5, 1024000)

set :session_secret, CONFIG['session_secret']
set :js, layout => false
use Rack::GoogleAnalytics, :tracker => CONFIG['tracker']

log.info("Server is set up at #{HOSTNAME}:#{PORT} with the SECRET=#{SECRET}")


db = "sqlite://#{Dir.pwd}/cmxtests.db"

if (PORT)
	set :port, PORT
end
if (CONFIG['bind'])
	set :bind, CONFIG['bind']
end
if (CONFIG['db_driver'])
	DB = Sequel.connect(CONFIG['db_driver'])
else
	DB = Sequel.connect("sqlite://#{Dir.pwd}/cmxtests.db")
end

DB.create_table? :tests do #Create the tests table if not exists
	primary_key :id
	String :name, :text => true, :null => false
	String :case, :null => false
	String :secret
	Float :api
	String :push_url
	String :validator, :null => false
	Boolean :complete, :default => false
	DateTime :created_at
	DateTime :updated_at
	DateTime :data_at
	String :state, :text => true
end
DB.create_table? :clients do # Create the clients table if not exists
	primary_key :id
	Integer :test
	String :mac, :key => true 
	String :seenString
	Integer :seenMillis, :default =>0
	Float :lat
	Float :lng
	Float :unc
	String :manufacturer
	String :os
	String :ssid
	String :floors
	DateTime :updated_at
	DateTime :created_at
end

Sequel::Model.plugin :validation_helpers
Sequel::Model.plugin :json_serializer, :naked => true #This ensures that we can convert to JSON  
class Client < Sequel::Model
	def before_create
		self.updated_at = Time.now
	end
	def before_save
		self.updated_at = Time.now
	end
	plugin :serialization, :json, :permissions
end
class Test < Sequel::Model
	def validate
		super
		validates_presence [:name, :case, :validator, :complete, :secret]
		validates_max_length 30, :name
		validates_max_length 20, :case
	end

	def before_create
		self.created_at = Time.now
		super
	end

	def before_save
		self.updated_at = Time.now
		super
	end
end

helpers do
	include Rack::Utils
	alias_method :h, :escape_html
end

def authorized?
  @auth ||= Rack::Auth::Basic::Request.new(request.env)
  @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [CONFIG['login'], CONFIG['password']]
end

def protected!
  unless authorized?
    response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
    throw(:halt, [401, "You shall not pass.\n"])
  end
end

# List all Tests
get "/list" do
  protected!
	@tests = DB[:tests]
	@title = "All Tests"
	if @tests.empty?
		flash[:error] = "No tests found."
	end
	erb :list
end

#Test
get "/data/:id" do
	@test = Test.first(:id => params[:id])
	if @test
		@test.validator
	else
		redirect "/", :error => "Can't find that test."
	end
end

#Recieve data
post "/data/:id" do
	n = Test.first(:id => params[:id]) #Find the test from the DB
	if n # if the tests exists
		currentTest = params[:id]
		n.data_at = Time.now #Current Time
		if request.media_type == "application/json" # If response is JSON, parse it
			request.body.rewind
			map = JSON.parse(request.body.read)
		else
			map = JSON.parse(params['data'])
		end
		
		if map == nil # We were not able to parse the post data
			request.body.rewind
			logger.warn "#{params[:id]} Could not parse POST body #{request.body.read}"
			log.warn("#{params[:id]} *** Could not parse POST body #{request.body.read}")
			n.state = "bad_post"
			n.save
			return
		end

		if map['secret'] != n.secret #Secret does not match the one in the test
			logger.warn "#{params[:id]} Got post with bad secret: #{map['secret']}"
			log.warn("#{params[:id]} *** bad secret #{map['secret']}")
			n.state = "bad_secret"
			n.save
			return
		end
	
		logger.info "Version is #{map['version']}" #API Version

		if map['version'] == '1.0'
			n.api = 1.0
			data = map['probing'].to_s #V1 stores data in probing var
		elsif map['version'] == '2.0'
			n.api = 2.0
			data = map['data'].to_s #V2 stores data in data	
		else #API Version that we dont know about
			log.warn("#{params[:id]} *** Test #{params[:id]} -- Unknown API version: #{map['version']}")
			n.api = map['version']
			n.state = "bad_api"
			n.save
			return
		end

		log.info("#{params[:id]} Post data -- (First 100 characters): #{data[0, 99]}#")
		n.state = "complete"
		n.complete = true
		n.save #Save the post
		
		if n.api == 2.0 #If the API is 2 then we will dump the data to the DB so that the map can use this
			if map['type'] != 'DevicesSeen'
				logger.warn "got post for event that we're not interested in: #{map['type']}"
				return
			end
			map['data']['observations'].each do |c|
				next if c['location'] == nil # We only want to store locations
				cl = Client.first(:mac => c['clientMac']) || Client.new
				loc = c['location']
				cl.mac = c['clientMac']
				cl.lat = loc['lat']
				cl.lng = loc['lng']
				cl.unc = loc['unc']
				cl.seenString = c['seenTime']
				cl.seenMillis = c['seenEpoch']
#				cl.floors = map['data']['apFloors'] == nil ? "" : map['data']['apFloors'].join #If this is empty then we store a string otherwise we concatonate them.
				cl.floors = "";
				cl.manufacturer = c['manufacturer']
				cl.os = cl.os = c['os']
				cl.test = currentTest
				cl.save
			end
		else
			log.error("***** Data recieved for unconfigured test #{params[:id]}")
		end
	end
end
# Home Page
get "/" do 
  protected!
	@tests = DB[:tests]
	@title = "All Tests"
	if @tests.empty?
		flash[:notice] = "No pending tests found. Add your first below."
	end
	@additional_js = '
        <script>
                $(document).ready( function () {
                        $("#all_tests").DataTable();
                });
        </script>
	'
	erb :home
end

# Post a test
post "/" do
  protected!
	n = Test.new
	n.secret = params[:secret] ? params[:secret] : SECRET
	n.validator = params[:content]
	n.name = params[:name]
	n.case = params[:case]
	n.complete = false
	n.push_url = "http://#{HOSTNAME}:#{PORT}/data/"
	n.state = "no_data_received"
  if n.valid?
    n.save
    flash[:notice] = "Test created successfully." 
		redirect "/"
	else
		flash[:error] = "Unable to save test, please make sure you fill out all fields"
    redirect "/"
  end
end

# Edit a test -- get
get "/:id/edit" do 
  protected!
	@test = Test.first(:id => params[:id])
	@title = "Edit test ##{params[:id]}"
	if @test
		erb :edit
	else 
		redirect "/", :error => "Can't find that test."
	end
end

# Edit a test -- post
post "/:id/edit" do
  protected!
	n = Test.first(:id => params[:id])
	unless n
		redirect "/", :error => "Can't find that test."
	end
	n.name = params[:name]
	n.case = params[:case]
	n.secret = params[:secret]
	n.validator = params[:validator]
	n.complete = params[:complete] ? 1 : 0
	n.state = "no_data_received"
	n.updated_at = Time.now
	if n.save
		redirect "/", :notice => "Test updated successfully."
	else
		redirect "/", :error => "Error updating test."
	end
end

# Delete a test -- get
get "/:id/delete" do
  protected!
	@test = Test.first(:id => params[:id])
	@title = "Confirm deletion of test ##{params[:id]}"
	if @test
		erb :delete
	else
		redirect "/", :error => "Can't find that test."
	end
end

# Delete a test -- delete
delete "/:id" do 
  protected!
	n = Test.first(:id => params[:id])
	if n.destroy
		redirect "/", :notice => "Test deleted successfully."
		log.info("Test #{:id} was deleted")
	else
		redirect "/", :error => "Error deleting Test."
	end
end

# Mark a Test complete -- get
get "/:id/complete" do
  protected!
	n = Test.first(:id => params[:id])
	unless n
		redirect "/", :error => "Can't find that test."
	end
	n.state = "complete"
	n.complete = n.complete ? 0 : 1 #flip it
	n.updated_at = Time.now
	if n.save
		redirect "/", :notice => "Test marked as complete."
	else
		redirect "/", :error => "Error marking test as complete."
	end
end
#Go to map
get "/:id/map" do
	id = params[:id]
	@test = Test.first(:id => params[:id])
	if @test
		@title = "Map for test ##{params[:id]}"
		@additional_js = "
			<script src=\"https://maps.googleapis.com/maps/api/js?v=3.exp&sensor=false\"></script>
			<script type=\"text/javascript\" src=\"/#{id}/mapjs\"></script>
		"
		erb :map
	else
		redirect "/", :error => "Error selecting test"
	end
end
#Make sure that the map can get the right ID
get '/:id/mapjs' do
	@testid = params[:id]
	content_type :js
	erb :mapjs, :layout=>false
end
#Get client
get '/:id/clients/:mac' do
  	mac = params[:mac]
	puts "Request name is #{mac}"
	content_type :json
	client = Client.first(:mac => mac, :test =>params[:id])
	logger.info("Retrieved client #{client}")
	client != nil ? JSON.generate(client) : "{}"
end

get '/:id/clients/' do
	content_type :json
	clients = Client.filter(:test => params[:id]).to_json
end

