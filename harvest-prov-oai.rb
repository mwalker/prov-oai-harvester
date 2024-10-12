# frozen_string_literal: true

require 'uri'
require 'json'
require 'date'
require 'fileutils'
require 'optparse'
require 'nokogiri'
require 'open-uri'
require 'reverse_markdown'

require 'byebug'

VERSION = '0.1.1'
OAI_PMH_SCHEMA_URL = 'http://www.openarchives.org/OAI/2.0/OAI-PMH.xsd'

class OAIHarvester
  attr_reader :raw_responses

  def initialize(base_url, request_interval = 1)
    @base_url = base_url
    @request_interval = request_interval
    @raw_responses = []
  end

  def harvest_records(use_saved_xml: false, xml_directory: nil)
    records = []
    resumption_token = nil
    request_count = 0
    total_records = 0

    puts 'Starting harvest...'
    loop do
      request_count += 1

      if use_saved_xml
        response = load_saved_xml(xml_directory, request_count)
        break if response.nil?
      else
        url = build_url(resumption_token)
        response = make_request(url)
        @raw_responses << response
      end

      xml = Nokogiri::XML(response, &:noblanks)

      error = xml.at_xpath('//oai:error', 'oai' => 'http://www.openarchives.org/OAI/2.0/')
      if error
        puts "Error encountered: #{error.text}"
        break
      end

      batch_size = xml.xpath('//oai:record', 'oai' => 'http://www.openarchives.org/OAI/2.0/').size
      total_records += batch_size

      xml.xpath('//oai:record', 'oai' => 'http://www.openarchives.org/OAI/2.0/').each_with_index do |record, _index|
        records << parse_record(record)
      end
      print "Processed request #{request_count}: #{batch_size}/#{total_records} processed records"
      puts '' # New line after batch completion

      resumption_token = xml.at_xpath('//oai:resumptionToken', 'oai' => 'http://www.openarchives.org/OAI/2.0/')&.text
      break if resumption_token.nil? || resumption_token.empty?

      sleep(@request_interval) unless use_saved_xml # Rate limiting only when making actual requests
    end

    puts "\nHarvest completed. Total records retrieved: #{total_records}"
    records
  end

  private

  def build_url(resumption_token)
    if resumption_token
      uri = URI(@base_url)
      query = URI.decode_www_form(uri.query || '')
      query.select! { |k, _| k == 'verb' } # Keep only the 'verb' parameter
      query << ['resumptionToken', resumption_token]
      uri.query = URI.encode_www_form(query)
      uri.to_s
    else
      @base_url
    end
  end

  def make_request(url)
    puts "\nRequesting: #{url}"
    response = URI.open(url).read
    puts "Response received. Size: #{response.bytesize} bytes"
    response
  end

  def load_saved_xml(directory, request_count)
    filename = File.join(directory, "response_#{request_count}.xml")
    if File.exist?(filename)
      puts "\nLoading saved XML: #{filename}"
      File.read(filename)
    else
      puts "\nNo more saved XML files found."
      nil
    end
  end

  def parse_record(record)
    rif = record.at_xpath('.//rif:registryObject', 'rif' => 'http://ands.org.au/standards/rif-cs/registryObjects')
    raw_description = rif.at_xpath('.//rif:description[@type="full"]', 'rif' => 'http://ands.org.au/standards/rif-cs/registryObjects')&.text
    # Clean the simple HTML markup to text and elimate spaces at the end of lines
    description = ReverseMarkdown.convert(raw_description).gsub(/[^\S\n]+$/, '').chomp('')
    {
      identifier: record.at_xpath('.//oai:identifier', 'oai' => 'http://www.openarchives.org/OAI/2.0/')&.text,
      datestamp: record.at_xpath('.//oai:datestamp', 'oai' => 'http://www.openarchives.org/OAI/2.0/')&.text,
      title: rif.at_xpath('.//rif:name/rif:namePart', 'rif' => 'http://ands.org.au/standards/rif-cs/registryObjects')&.text,
      description: description
    }
  end
end

def custom_identifier_sort(identifier)
  parts = identifier.split
  parts.fill('', parts.length...3)
  numeric_part = parts.last.to_i
  [parts[0], parts[1], numeric_part]
end

def save_to_json(records, filename, split = false)
  sorted_records = records.sort_by { |record| custom_identifier_sort(record[:identifier]) }

  if split
    agencies, functions, series = split_records(sorted_records)
    save_json(agencies, filename.sub('prov-oai', 'prov-oai-agencies'))
    save_json(functions, filename.sub('prov-oai', 'prov-oai-functions'))
    save_json(series, filename.sub('prov-oai', 'prov-oai-series'))
  else
    save_json(sorted_records, filename)
  end
end

def save_json(records, filename)
  File.open(filename, 'w') do |file|
    file.write(JSON.pretty_generate(records))
  end
  puts "Sorted records saved to #{filename}"
end

def split_records(records)
  agencies = records.select { |r| r[:identifier].start_with?('PROV VA ') }
  functions = records.select { |r| r[:identifier].start_with?('PROV VF ') }
  series = records.select { |r| r[:identifier].start_with?('PROV VPRS ') }
  [agencies, functions, series]
end

def save_to_xml(responses, filename, split = false)
  if split
    [
      { prefix: 'PROV VA ', type: 'agencies' },
      { prefix: 'PROV VF ', type: 'functions' },
      { prefix: 'PROV VPRS ', type: 'series' }
    ].each do |kind|
      build_xml(responses, filename.sub('prov-oai', "prov-oai-#{kind[:type]}"), kind[:prefix])
    end
  else
    build_xml(responses, filename)
  end
end

def build_xml(responses, filename, prefix = nil)
  doc = Nokogiri::XML::Document.new
  doc.encoding = 'UTF-8'
  root = Nokogiri::XML::Node.new('OAI-PMH', doc)
  root['xmlns'] = 'http://www.openarchives.org/OAI/2.0/'
  root['xmlns:xsi'] = 'http://www.w3.org/2001/XMLSchema-instance'
  root['xsi:schemaLocation'] = 'http://www.openarchives.org/OAI/2.0/ http://www.openarchives.org/OAI/2.0/OAI-PMH.xsd'
  doc.add_child(root)

  # Add responseDate and request elements from the first response
  first_response = Nokogiri::XML(responses.first, &:noblanks)
  response_date = first_response.at_xpath('//oai:responseDate', 'oai' => 'http://www.openarchives.org/OAI/2.0/')
  request = first_response.at_xpath('//oai:request', 'oai' => 'http://www.openarchives.org/OAI/2.0/')
  root.add_child(response_date.dup) if response_date
  root.add_child(request.dup) if request

  # Collect all records from all responses
  all_records = []
  responses.each do |response|
    xml = Nokogiri::XML(response, &:noblanks)
    all_records.concat(xml.xpath('//oai:record', 'oai' => 'http://www.openarchives.org/OAI/2.0/'))
  end

  # Sort all records
  sorted_records = all_records.sort_by do |record|
    identifier = record.at_xpath('.//oai:identifier', 'oai' => 'http://www.openarchives.org/OAI/2.0/')&.text || ''
    custom_identifier_sort(identifier)
  end

  list_records = Nokogiri::XML::Node.new('ListRecords', doc)
  root.add_child(list_records)
  # Add sorted and filtered records to the document
  sorted_records.each do |record|
    list_records.add_child(record.dup) if prefix.nil? || record.at_xpath('.//oai:identifier', 'oai' => 'http://www.openarchives.org/OAI/2.0/')&.text&.start_with?(prefix)
  end
  save_xml(doc, filename)
end

def save_xml(doc, filename)
  # Remove any resumptionToken elements
  doc.xpath('//oai:resumptionToken', 'oai' => 'http://www.openarchives.org/OAI/2.0/').each(&:remove)

  File.open(filename, 'w') do |file|
    file.write(doc.to_xml(indent: 1))
  end
  puts "Sorted, pretty-printed combined XML without resumption tokens saved to #{filename}"

  validate_xml(filename)
end

def validate_xml(filename)
  puts "Validating XML file: #{filename}"

  doc = Nokogiri::XML(File.read(filename))

  begin
    schema = Nokogiri::XML::Schema(URI.open(OAI_PMH_SCHEMA_URL))
    puts "Successfully loaded OAI-PMH schema from #{OAI_PMH_SCHEMA_URL}"
  rescue SocketError, OpenURI::HTTPError => e
    puts "Failed to load OAI-PMH schema: #{e.message}"
    puts 'Skipping validation.'
    return
  end

  errors = schema.validate(doc)

  errors.reject! do |error|
    # FIXME: this also seems to be an issue with the raw XML, so ignore it for now
    error.message.include?("Element '{http://ands.org.au/standards/rif-cs/registryObjects}registryObjects': No matching global element declaration available, but demanded by the strict wildcard")
  end

  if errors.empty?
    puts "XML is valid according to the OAI-PMH schema, excluding known issues with 'http://ands.org.au/standards/rif-cs/registryObjects'."
  else
    puts "XML validation errors, excluding known issues with '{http://ands.org.au/standards/rif-cs/registryObjects}registryObjects':"
    errors.each do |error|
      puts error.message
    end
  end
end

def save_raw_xml(responses, directory)
  FileUtils.mkdir_p(directory)
  responses.each_with_index do |response, index|
    filename = File.join(directory, "response_#{index + 1}.xml")
    File.open(filename, 'w') do |file|
      file.write(response)
    end
  end
  puts "Raw XML responses saved to #{directory}"
end

# Parse command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby #{File.basename(__FILE__)} [options]"

  opts.on('-s', '--save-raw-xml DIR', 'Save raw XML to the specified directory') do |dir|
    options[:save_xml] = dir
  end

  opts.on('-u', '--use-saved-raw-xml DIR', 'Use saved raw XML from the specified directory') do |dir|
    options[:use_saved_xml] = dir
  end

  opts.on('-h', '--help', 'Prints this help') do
    puts opts
    exit
  end

  opts.on('-v', '--version', 'Prints version information') do
    puts "PROV OAI Harvester version #{VERSION}"
    exit
  end

  opts.on('--split', 'Split output into separate files for agencies, functions, and series') do
    options[:split] = true
  end
end.parse!

# Usage
base_url = 'http://metadata.prov.vic.gov.au/oai/query?verb=ListRecords&metadataPrefix=rif'
harvester = OAIHarvester.new(base_url, 2) # 2-second interval between requests

if options[:use_saved_xml]
  puts "Using saved XML from directory: #{options[:use_saved_xml]}"
  records = harvester.harvest_records(use_saved_xml: true, xml_directory: options[:use_saved_xml])
else
  records = harvester.harvest_records
end

# Generate filenames with current date
current_date = Date.today.strftime('%Y-%m-%d')
json_filename = "prov-oai-#{current_date}.json"
xml_filename = "prov-oai-#{current_date}.xml"

# Save sorted records to JSON file
save_to_json(records, json_filename, options[:split])

# Save raw XML responses if we're not using saved XML
if options[:use_saved_xml]
  # If using saved XML, combine and sort the saved files
  saved_responses = Dir[File.join(options[:use_saved_xml], 'response_*.xml')].sort.map { |f| File.read(f) }
  save_to_xml(saved_responses, xml_filename, options[:split])
else
  save_raw_xml(harvester.raw_responses, options[:save_xml]) if options[:save_xml]

  # Save combined and sorted XML
  save_to_xml(harvester.raw_responses, xml_filename, options[:split])
end

puts "\n\nSample of retrieved records:"
records.first(5).each do |record|
  puts "ID: #{record[:identifier]}, Title: #{record[:title]}"
end
