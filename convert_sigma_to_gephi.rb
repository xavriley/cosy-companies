require 'json'
require 'csv'

ARGF.each(nil) do |line|
  graph = JSON.parse(line)
  nodes = graph["nodes"]
  edges = graph["edges"]

  CSV.open('nodes.csv', 'w') do |csv|
    csv << nodes.first.keys # adds the attributes name on the first line
    nodes.each do |hash|
      csv << hash.values
    end
  end

  CSV.open('edges.csv', 'w') do |csv|
    csv << edges.first.keys # adds the attributes name on the first line
    edges.each do |hash|
      csv << hash.values
    end
  end
end
