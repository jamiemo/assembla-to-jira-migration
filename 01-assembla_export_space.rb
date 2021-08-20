# frozen_string_literal: true

load './lib/common.rb'

ALLOWED_ARGS = %w(space_tools users user_roles tags milestones/all tickets/statuses tickets/custom_fields documents wiki_pages tickets).freeze

if ARGV[0].nil?
  puts "\nExport all: #{ALLOWED_ARGS.join(', ')}"
else
  goodbye("Invalid arg='#{ARGV[0]}', must be one of: #{ALLOWED_ARGS.join(', ')}") unless ALLOWED_ARGS.include?(ARGV[0])
  puts "Export only: #{ARGV[0]}"
end
puts

ITEMS = [
  { name: 'space_tools' },
  # space-tools.csv
  # id,space_id,active,url,number,tool_id,type,created_at,team_permissions,watcher_permissions,public_permissions,
  # parent_id,menu_name,name
  { name: 'users' },
  # users.csv
  # id,login,name,picture,email,organization,phone,im,im2
  { name: 'user_roles' },
  # user-roles.csv
  # id,user_id,space_id,role,status,invited_time,agreed_time,title,invited_by_id
  { name: 'tags', q: 'per_page=25' },
  # user-tags.csv
  # id,name,space_id,state,created_at,updated_at,color
  { name: 'milestones/all', q: 'per_page=10' },
  # milestones-all.csv
  # id,start_date,due_date,budget,title,user_id,created_at,created_by,space_id,description,is_completed,completed_date,
  # updated_at,updated_by,release_level,release_notes,planner_type,pretty_release_level
  { name: 'tickets/statuses' },
  # tickets-statuses.csv
  # id,space_tool_id,name,state,list_order,created_at,updated_at
  { name: 'tickets/custom_fields' },
  # tickets-custom-fields.csv
  # id,space_tool_id,type,title,order,required,hide,default_value,created_at,updated_at,example_value,list_options
  { name: 'documents', q: 'per_page=100' },
  # documents.csv
  # name,content_type,created_by,id,version,filename,filesize,updated_by,description,cached_tag_list,position,url,
  # created_at,updated_at,ticket_id,attachable_type,has_thumbnail,space_id,attachable_id,attachable_guid
  { name: 'wiki_pages', q: 'per_page=10' },
  # wiki-pages.csv
  # id,page_name,contents,status,version,position,wiki_format,change_comment,parent_id,space_id,user_id,created_at,
  # updated_at
  { name: 'tickets', q: "report=#{ASSEMBLA_TICKET_REPORT}&sort_by=number&per_page=100" }
  # tickets.csv
  # id,number,summary,description,priority,completed_date,component_id,created_on,permission_type,importance,is_story,
  # milestone_id,notification_list,space_id,state,status,story_importance,updated_at,working_hours,estimate,
  # total_estimate,total_invested_hours,total_working_hours,assigned_to_id,reporter_id,custom_fields,hierarchy_type,
  # due_date,assigned_to_name,picture_url
].freeze

if ARGV[0].nil?
  items = ITEMS
else
  items = [ ITEMS.find { |item| item[:name] == ARGV[0] } ]
end

spaces = assembla_get_spaces

# Make sure that the space name is known
unless spaces.detect{ |space| space['name'] == ASSEMBLA_SPACE}
  goodbye("Unknown ASSEMBLA_SPACE='#{ASSEMBLA_SPACE}' must be one of the following:\n#{spaces.map{ |space| space['name']}}")
end

puts "\nFound ASSEMBLA_SPACE='#{ASSEMBLA_SPACE}'"

write_csv_file("#{OUTPUT_DIR_ASSEMBLA}/spaces.csv", spaces)

export_assembla_items(items)
