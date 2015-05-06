require 'json'
require 'sinatra'
require 'rack/cache'
require 'dalli'
require 'typhoeus'
require 'csv'

if memcachier_servers = ENV["MEMCACHIER_SERVERS"]
  @cache = Dalli::Client.new(memcachier_servers.split(','), {
    username: ENV['MEMCACHIER_USERNAME'],
    password: ENV['MEMCACHIER_PASSWORD']
  })
  use Rack::Cache, verbose: true, metastore: @cache, entitystore: @cache
elsif memcache_servers = ENV["MEMCACHE_SERVERS"]
  use Rack::Cache,
    verbose: true,
    metastore:   "memcached://#{memcache_servers}",
    entitystore: "memcached://#{memcache_servers}"
end
use Rack::Deflater
set :static_cache_control, [:public, max_age: 60 * 60 * 24 * 365]

class HydraCache
  def initialize(cache)
    @client = cache || Dalli::Client.new
  end

  def get(request)
    @client.get(request.cache_key)
  end

  def set(request, response)
    @client.set(request.cache_key, response)
  end
end

Typhoeus::Config.cache = HydraCache.new(@cache)

before do
  @max_nodes = 500
  @nodes = {}
  @edges = []
  @hydra = Typhoeus::Hydra.new
  @api_key = ENV['OPENC_API_KEY']
  headers 'Access-Control-Allow-Origin' => '*',
    'Access-Control-Allow-Methods' => ['OPTIONS', 'GET', 'POST']
end

def get_address(company_results)
  if address = company_results["results"]["company"]["registered_address_in_full"]
    address
  elsif address = company_results["results"]["company"]["data"]["most_recent"].select {|datum| datum["data_type"] == "CompanyAddress" }.first
    address["description"]
  end
end

def get_officer_names(company_results)
  Array(company_results["results"]["company"]["officers"]).map {|x| x["officer"]["name"].strip }
end

def get_name(company_results)
  company_results["results"]["company"]["name"]
end

def queue_get(url)
  request = Typhoeus::Request.new(url)
  @hydra.queue(request)
  request
end

def get_company(url_or_id)
  id = url_or_id.gsub(/https?:\/\/opencorporates\.com\/companies\/gb\//, '').strip
  url = "http://api.opencorporates.com/companies/gb/#{id}?api_token=#{@api_key}"
  $stderr.puts url
  body = Typhoeus::Request.get(url).body
  JSON.parse(body)
end

def coord_from_name(name)
  Digest::MD5.hexdigest(name)[/\d{,1}/].to_i
end

def nodes_and_edges_for_company(company_number)
  root_company = get_company(company_number)

  rc_name = get_name(root_company)
  rc_address = get_address(root_company)
  rc_officer_names = get_officer_names(root_company)

  rc_postcode = rc_address.to_s.split(/[,\n]+/).map(&:strip).select {|line|
    line[/\A[A-Z0-9]{2,4}\s[A-Z0-9]{2,4}\Z/]
  }.first

  if rc_postcode.to_s.empty?
    $stderr.puts "WARNING: postcode not found #{rc_address}"
    return [[], []]
  end

  candidate_companies_query = JSON.parse(Typhoeus::Request.get("https://api.opencorporates.com/companies/search?api_token=#{@api_key}&jurisdiction_code=gb&per_page=100&registered_address=#{URI.encode(rc_postcode)}").body)
  no_pages = candidate_companies_query["results"]["total_pages"].to_i
  nodes = []
  edges = []
  nodes << {id: rc_name,
            label: rc_name,
            size: 3,
            color: "125,125,225",
            type: "related_company",
            opencorporates_url: root_company["results"]["company"]["opencorporates_url"]
        }

  # add root company and postcode
  nodes << {id: rc_postcode,
            label: rc_postcode,
            size: 5,
            color: "125,255,125",
            type: "postcode",
            opencorporates_url: ""
        }
  edges << {id: Digest::MD5.hexdigest(rc_name + rc_postcode), source: rc_name, target: rc_postcode, label: "registered at"}

  # add root officers
  rc_officer_names.each do |oname|
    nodes << {id: "#{oname} (officer)",
              label: oname,
              size: 2,
              color: "255,125,125",
              type: "officer",
              opencorporates_url: ""
              }
    edges << {id: Digest::MD5.hexdigest(oname + rc_name), source: "#{oname} (officer)", target: rc_name, label: "officer of"}
  end

  (1..no_pages).each do |i|
    candidate_companies_query = JSON.parse(Typhoeus::Request.get("https://api.opencorporates.com/companies/search?api_token=#{@api_key}&jurisdiction_code=gb&per_page=100&page=#{i}&registered_address=#{URI.encode(rc_postcode)}").body)
    candidate_company_results = candidate_companies_query["results"]["companies"].map {|x| x["company"] }

    candidate_companies = candidate_company_results.map do |c|
      c_full_url = "http://api.opencorporates.com/companies/#{c['jurisdiction_code']}/#{c['company_number']}?api_token=#{@api_key}"
      queue_get(c_full_url) # hydra parses the reponse body to json
    end

    @hydra.run

    candidate_companies.map {|r|
      JSON.parse(r.response.body)
    }.each do |c_full|
      next if c_full["results"]["company"]["name"] == rc_name

      c_address = get_address(c_full)
      c_officers = get_officer_names(c_full)


      matching_officers = rc_officer_names & c_officers
      if !matching_officers.empty?
        # mark the company as related
        mc_name = c_full["results"]["company"]["name"]
        mc_address = c_full["results"]["company"]["registered_address_in_full"]
        nodes << {id: mc_name,
                  label: mc_name,
                  size: 1,
                  color: "125,125,225",
                  type: "related_company",
                  opencorporates_url: c_full["results"]["company"]["opencorporates_url"]}

        # add candidate officers
        c_officers.each do |oname|
          nodes << {id: "#{oname} (officer)",
                    label: oname,
                    size: 2,
                    color: "225,125,125",
                    type: "related_officer",
                    opencorporates_url: ""}
          edges << {id: Digest::MD5.hexdigest(oname + mc_name), source: "#{oname} (officer)", target: mc_name, label: "officer of"}
        end

        matching_officers.each do |oname|
          edges << {id: Digest::MD5.hexdigest(oname + rc_name), source: "#{oname} (officer)", target: rc_name, label: "officer of"}
        end

        # match company to address
        edges << {id: Digest::MD5.hexdigest(mc_name + rc_postcode), source: mc_name, target: rc_postcode, label: "registered at"}
      elsif params[:show_all]
        # add the company anyway
        mc_name = c_full["results"]["company"]["name"]
        mc_address = c_full["results"]["company"]["registered_address_in_full"]
        nodes << {id: mc_name,
                  label: mc_name,
                  size: 1,
                  color: "125,125,255",
                  type: "company",
                  opencorporates_url: c_full["results"]["company"]["opencorporates_url"]}

        # add candidate officers
        c_officers.each do |oname|
          nodes << {id: "#{oname} (officer)",
                    label: oname,
                    size: 2,
                    color: "255,125,125",
                    type: "officer",
                    opencorporates_url: ""}
          edges << {id: Digest::MD5.hexdigest(oname + mc_name), source: "#{oname} (officer)", target: mc_name, label: "officer of"}
        end

        # match company to address
        edges << {id: Digest::MD5.hexdigest(mc_name + rc_postcode), source: mc_name, target: rc_postcode, label: "registered at"}
      end

    end
  end

  nodes = nodes.uniq {|n| n[:id] }
  edges = edges.uniq

  [nodes, edges]
end

get '/' do
  @id = params[:query] ||"OC325892"
  erb :index
end

get '/json/:company_number' do
  nodes, edges = nodes_and_edges_for_company(params[:company_number])

  json_out = JSON.dump({
    nodes: nodes.map {|x| x.merge(x: rand(20), y: rand(20)).merge(color: "rgb(#{x[:color]})") },
    edges: edges
  })

  cache_control :public, max_age: (1 * 86400) # one week
  content_type :json

  json_out
end

get '/multi' do
  erb :multi
end

post '/multi' do
  @nodes = Set.new
  @edges = Set.new
  params[:company_numbers].split(/\n/).each do |company|
    $stderr.puts "Processing nodes and edges for #{company}"
    nodes, edges = nodes_and_edges_for_company(company)
    @nodes += Array(nodes)
    @edges += Array(edges)
  end

  puts @nodes.length
  puts @edges.length

  # prefer the related officer classifications
  # @nodes.keep_if {|n|
  #   @nodes.select {|tn| tn.fetch(:id) == n[:id] }.count == 1 || n[:type] =~ /related/
  # }

  json_out = JSON.dump({
    nodes: @nodes.to_a.map {|x| x.merge(x: rand(20), y: rand(20)) },
    edges: @edges.to_a
  })

  content_type :json

  json_out
end

get '/csv/nodes/:company_number' do
  nodes, edges = nodes_and_edges_for_company(params[:company_number])

  csv_out = CSV.generate do |csv|
    csv << nodes.first.keys # adds the attributes name on the first line
    nodes.each do |hash|
      csv << hash.values
    end
  end

  cache_control :public, max_age: (1 * 86400) # one week
  content_type :csv

  csv_out
end

get '/csv/edges/:company_number' do
  nodes, edges = nodes_and_edges_for_company(params[:company_number])

  csv_out = CSV.generate do |csv|
    csv << edges.first.keys # adds the attributes name on the first line
    edges.each do |hash|
      csv << hash.values
    end
  end

  cache_control :public, max_age: (1 * 86400) # one week
  content_type :csv

  csv_out
end

get '/about' do
  erb :about
end

get '/credits' do
  erb :credits
end
