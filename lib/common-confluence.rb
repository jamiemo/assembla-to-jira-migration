# frozen_string_literal: true

require 'json'
require 'csv'
require 'fileutils'
require 'dotenv/load'
require 'rest-client'
require 'base64'
require 'htmlbeautifier'

# Check that the correct ruby version is being used.
version = File.read('.ruby-version').strip
puts "Ruby version: #{RUBY_VERSION}"
unless RUBY_VERSION == version
  puts "Ruby version = '#{version}' is required, run the following command first:"
  puts "rvm use #{version}"
  exit
end

# Load environment
DEBUG = ENV['CONFLUENCE_DEBUG'] == 'true'
WIKI = ENV['ASSEMBLA_WIKI'] || throw('ASSEMBLA_WIKI must be defined')
WIKI_NAME = ENV['ASSEMBLA_WIKI_NAME'] || throw('ASSEMBLA_WIKI_NAME must be defined')
API = ENV['CONFLUENCE_API'] || throw('CONFLUENCE_API must be defined')
API_KEY = ENV['CONFLUENCE_API_KEY'] || throw('CONFLUENCE_API_KEY must be defined')
SPACE = ENV['CONFLUENCE_SPACE'] || throw('CONFLUENCE_SPACE must be defined')
EMAIL = ENV['CONFLUENCE_EMAIL'] || throw('CONFLUENCE_EMAIL must be defined')
PASSWORD = ENV['CONFLUENCE_PASSWORD'] || throw('CONFLUENCE_PASSWORD must be defined')

# Define directories
DATA_DIR = output_dir_confluence(ASSEMBLA_SPACE)
IMAGES_DIR = "#{DATA_DIR}/images"
DOCUMENTS_DIR = "#{DATA_DIR}/documents"

# Define locations of CSV files
LINKS_CSV = "#{DATA_DIR}/links.csv"
UPLOADED_IMAGES_CSV = "#{DATA_DIR}/uploaded-images.csv"
UPLOADED_DOCUMENTS_CSV = "#{DATA_DIR}/uploaded-documents.csv"
CREATED_PAGES_CSV = "#{DATA_DIR}/created-pages.csv"
CREATED_PAGES_NOK_CSV = "#{DATA_DIR}/created-pages-nok.csv"
UPDATED_PAGES_CSV = "#{DATA_DIR}/updated-pages.csv"
WIKI_FIXED_CSV = "#{DATA_DIR}/wiki-pages-fixed.csv"
WIKI_DOCUMENTS_CSV = "#{DATA_DIR}/wiki-documents.csv"
WIKI_TICKETS_CSV = "#{DATA_DIR}/wiki-tickets.csv"
CHECK_TICKETS_CSV = "#{DATA_DIR}/check-tickets.csv"

# Display environment
puts
puts "DEBUG:        : '#{DEBUG}'"
puts "WIKI          : '#{WIKI}'"
puts "WIKI_NAME     : '#{WIKI_NAME}'"
puts "API           : '#{API}'"
puts "SPACE         : '#{SPACE}'"
puts "EMAIL         : '#{EMAIL}'"
puts
puts "DATA_DIR      : '#{DATA_DIR}'"
puts "IMAGES_DIR    : '#{IMAGES_DIR}'"
puts "DOCUMENTS_DIR : '#{DOCUMENTS_DIR}'"
puts

# Create directories if not already present
[DATA_DIR, IMAGES_DIR, DOCUMENTS_DIR].each { |dir| Dir.mkdir(dir) unless File.exist?(dir) }

# Authentication header
base64_admin = Base64.strict_encode64(JIRA_API_ADMIN_EMAIL + ':' + JIRA_API_KEY).gsub(/\n/, '')

HEADERS = {
    'Authorization': "Basic #{base64_admin}",
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json'
}.freeze

def fix_text(text)
  CGI.escapeHTML(text).gsub(/(?:\n\r?|\r\n?)/, '<br/>')
end

# The Assembla HTML is a complete mess! Ensure that the html can be  parsed
# by the confluence api, e.g. avoid the dreaded 'error parsing xhtml' error.
def fix_html(html)
  result = html.
      gsub('<package>', '&lt;package&gt;').
      # replace all strike-tags with del-tags.
      gsub(/<strike[^>]*?>/, '<del>').
      gsub('</strike>', '</del>').
      # remove all span-, font- or colgroup-tags
      gsub(%r{</?(span|font|colgroup)([^>]*?)>}, '').
      # strip down all h-tags
      gsub(/(<h[1-6])(.*?)>/, '\1>').
      # fix all unclosed col- and img-tags
      gsub(%r{(<(col|img)[^>]+)(?<!/)>}, '\1/>').
      # strip down all li tags
      gsub(/<li[^>]*?>/, '<li>').
      # strip down all br-tags and ensure closed.
      gsub(/<wbr(.*?)>/, '<wbr/>').
      gsub(/<br(.*?)>/, '<br/>')
  begin
    result = HtmlBeautifier.beautify(result)
  rescue RuntimeError => e
    puts "HtmlBeautifier error (#{e}) => SKIP"
  end

  result
end

@assembla_space = get_space(ASSEMBLA_SPACE)
if @assembla_space
  puts "Found assembla space='#{ASSEMBLA_SPACE}' => OK"
else
  puts "Cannot find assembla space='#{ASSEMBLA_SPACE}' => OK"
  exit
end
