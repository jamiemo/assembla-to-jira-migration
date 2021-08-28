# frozen_string_literal: true

load './lib/common.rb'
load './lib/common-confluence.rb'
load './lib/confluence-api.rb'

def abort(message)
  puts "ERROR: #{message} => EXIT"
  exit
end

def format_created_at(created_at)
  created_at.sub(/\.[^.]*$/, '').tr('T', ' ')
end

# Set to true if you just want to run and verify this script without actually updating any external links.
@dry_run = true

# You can also pass a parameter 'dry_run=true|false'
if ARGV.length == 1
  goodbye("Invalid ARGV0='#{ARGV[0]}', must be 'dry_run=true|false'") unless /^dry_run=(true|false)$/i.match?(ARGV[0])
  @dry_run = ARGV[0].split('=')[1].casecmp('true') == 0
  puts "Detected ARGV0='#{ARGV[0]}' => #{@dry_run}"
end

if @dry_run
  puts
  puts '----------------'
  puts 'DRY RUN enabled!'
  puts '----------------'
  puts
end

spaces_assembla_csv = "#{OUTPUT_DIR_ASSEMBLA}/spaces.csv"
@assembla_spaces_csv = csv_to_array(spaces_assembla_csv)

@wiki_ids = {}
@wiki_names = {}
@wiki_wiki_names = {}
@id_to_wiki_name = {}

puts "\nTotal Assembla space: #{@assembla_spaces_csv.count}"
# id,name,description,wiki_name,public_permissions,team_permissions,watcher_permissions,share_permissions,team_tab_role,created_at,updated_at,default_showpage,parent_id,restricted,restricted_date,commercial_from,banner,banner_height,banner_text,banner_link,style,status,approved,is_manager,is_volunteer,is_commercial,can_join,can_apply,last_payer_changed_at,prefix
@assembla_spaces_csv.each do |space|
  id = space['id']
  name = space['name']
  wiki_name = space['wiki_name']
  puts "* id='#{id}' name='#{name}' wiki_name='#{wiki_name}'"
  @wiki_ids[id] = true
  @wiki_names[name] = true
  @wiki_wiki_names[wiki_name] = true
  @id_to_wiki_name[id] = wiki_name
end

# Return true of the src contains either the wiki name or wiki id in the path.
def is_wiki_space(src)
  # src="https://eu-app.assembla.com/spaces/ddLL8mW7rcHOkFmHBdOmo2/documents/ckzETUjw0r6OkEaMlMwbiA/download/ckzETUjw0r6OkEaMlMwbiA"
  @assembla_spaces_csv.each do |space|
    wiki_name = space['wiki_name']
    id = space['id']
    return true if %r{/#{id}|#{wiki_name}/}.match?(src)
  end
  false
end

attachments_jira_csv = "#{OUTPUT_DIR_JIRA}/jira-attachments-download.csv"
if File.exist?(attachments_jira_csv)
  @jira_attachments_csv = csv_to_array(attachments_jira_csv)
else
  puts "\nCould not find file '#{attachments_jira_csv}', assuming that there are no attachments."
  @jira_attachments_csv = []
end

@a_attachment_id_to_j_filename = {}

puts "\nTotal Jira attachments: #{@jira_attachments_csv.count}"
# created_at,created_by,assembla_attachment_id,assembla_ticket_id,filename,content_type
@jira_attachments_csv.each do |attachment|
  assembla_attachment_id = attachment['assembla_attachment_id']
  filename = attachment['filename']
  puts "* assembla_attachment_id='#{assembla_attachment_id}' filename='#{filename}'"
  @a_attachment_id_to_j_filename[assembla_attachment_id] = filename
end

# result,retries,message,jira_ticket_id,jira_ticket_key,project_id,summary,issue_type_id,issue_type_name,
# assignee_name,reporter_name,priority_name,status_name,labels,description,assembla_ticket_id,assembla_ticket_number,
# milestone_name,story_rank
tickets_jira_csv = "#{OUTPUT_DIR_JIRA}/jira-tickets.csv"
@jira_tickets_csv = csv_to_array(tickets_jira_csv).select { |ticket| ticket['result'] == 'OK' }

# Check for duplicates just in case.
@assembla_nr_to_jira_key = {}
duplicates = []

@jira_tickets_csv.sort_by { |ticket| ticket['assembla_ticket_number'].to_i }.each do |ticket|
  nr = ticket['assembla_ticket_number']
  key = ticket['jira_ticket_key']
  if @assembla_nr_to_jira_key[nr]
    duplicates << { nr: nr, key: key }
  else
    @assembla_nr_to_jira_key[nr] = key
  end
end

if duplicates.length.positive?
  puts "\nDuplicates found: #{duplicates}\n"
  duplicates.each do |duplicate|
    puts "* #{duplicate[:nr]} #{duplicate[:key]}"
  end
end

# id,page_name,contents,status,version,position,wiki_format,change_comment,parent_id,space_id,
# user_id,created_at,updated_at
#
# wiki_format:
# 1 => text
# 3 => html

wiki_assembla_csv = "#{OUTPUT_DIR_ASSEMBLA}/wiki-pages.csv"
@wiki_assembla = []
csv_to_array(wiki_assembla_csv).each do |wiki|
  wiki['contents'] = wiki['wiki_format'].to_i == 3 ? fix_html(wiki['contents']) : fix_text(wiki['contents'])
  @wiki_assembla << wiki
end

write_csv_file(WIKI_FIXED_CSV, @wiki_assembla)

@wiki_assembla = csv_to_array(WIKI_FIXED_CSV)

# id,number,summary,description,priority,completed_date,component_id,created_on,permission_type,importance,is_story,
# milestone_id,notification_list,space_id,state,status,story_importance,updated_at,working_hours,estimate,
# total_estimate,total_invested_hours,total_working_hours,assigned_to_id,reporter_id,custom_fields,hierarchy_type,
# due_date,assigned_to_name,picture_url
tickets_assembla_csv = "#{OUTPUT_DIR_ASSEMBLA}/tickets.csv"
@tickets_assembla = csv_to_array(tickets_assembla_csv)

# id,login,name,picture,email,organization,phone
users_assembla_csv = "#{OUTPUT_DIR_ASSEMBLA}/users.csv"
@users_assembla = csv_to_array(users_assembla_csv)

@pages = {}
@created_pages = []

@total_wiki_pages = @wiki_assembla.length
# puts "\n--- Wiki pages: #{@total_wiki_pages} ---\n"

@wiki_assembla.each do |wiki|
  id = wiki['id']
  # wiki['page_name'].tr!('_', ' ')
  page_name = wiki['page_name']
  abort "Duplicate id='#{id}'" if @pages[id]
  abort "Duplicate page_name='#{page_name}'" if @pages.detect { |_, value| value[:page]['page_name'] == page_name }
  @pages[id] = { page: wiki, children_ids: [] }
end

def show_page(id, offset = [])
  # puts "show_page() id='#{id}' offset=[#{offset.join(',')}]"
  pages_id = @pages[id]
  page = pages_id[:page]
  page_name = page['page_name']
  parent_id = page['parent_id'] ? "parent_id='#{page['parent_id']}'" : ''
  created_at = format_created_at(page['created_at'])
  children_ids = pages_id[:children_ids]
  children_ids = 'children_ids=' + (children_ids.length.positive? ? "#{children_ids.length} [#{children_ids.join(',')}]" : '0')

  tree = offset.join('-')
  tree += ' ' if tree.length.positive?
  puts "#{tree}id='#{id}' #{parent_id}created_at='#{created_at}' page_name='#{page_name}' #{children_ids}"
end

def show_page_tree(id, offset)
  # puts "show_page_tree() id='#{id}' offset=[#{offset.join(',')}]"
  show_page(id, offset)
  pages_id = @pages[id]
  children_ids = pages_id[:children_ids]
  return unless children_ids.length.positive?

  # Child pages sorted by created_at
  children_ids.sort_by! { |child_id| @pages[child_id][:page]['created_at'] }
  children_ids.each_with_index { |child_id, index| show_page_tree(child_id, offset.dup << index) }
end

def create_all_pages(id, offset)
  # puts "create_all_pages() id='#{id}' offset=[#{offset.join(',')}]"
  create_page_item(id, offset)
  @pages[id][:children_ids].each_with_index { |child_id, index| create_all_pages(child_id, offset.dup << index) }
end

def get_all_links
  links = []
  # wiki_assembla => id,page_name,contents,status,version,position,wiki_format,change_comment,parent_id,space_id,
  # user_id,created_at,updated_at
  @wiki_assembla.each do |wiki|
    counter = 0
    id = wiki['id']
    content = wiki['contents']
    title = wiki['page_name']

    # <img ... src="(value)" ... />
    # <img alt="" src="https://eu-app.assembla.com/spaces/ddLL8mW7rcHOkFmHBdOmo2/documents/ckzETUjw0r6OkEaMlMwbiA/download/ckzETUjw0r6OkEaMlMwbiA" />
    content.scan(%r{<img(?:.*?)? src="(.*?)"(?:.*?)?/?>}).each do |m|
      value = m[0]
      next unless is_wiki_space(value)

      segments = value.split('/')
      attachment_id = segments.last
      filename = @a_attachment_id_to_j_filename[attachment_id]

      counter += 1
      links << {
        id: id,
        counter: counter,
        title: title,
        tag: 'image',
        value: value,
        text: ''
      }
    end

    # <a ... href="(value)" ...>(title)</a>
    content.scan(%r{<a(?:.*?)? href="(.*?)"(?:.*?)?>(.*?)</a>}).each do |m|
      value = m[0]
      next unless is_wiki_space(value)

      text = m[1]
      counter += 1
      links << {
        id: id,
        counter: counter,
        title: title,
        tag: 'anchor',
        value: value,
        text: text
      }
    end

    # [[page]]
    content.scan(/\[\[(.*?)\]\]/).each do |m|
      value = m[0]
      text = m[1]
      counter += 1
      links << {
        id: id,
        counter: counter,
        title: title,
        tag: 'markdown',
        value: value,
        text: text
      }
    end

    # <pre>...</pre>
    content.scan(%r{<pre>(.*?)</pre>}).each do |m|
      value = m[0]
      text = m[1]
      counter += 1
      links << {
        id: id,
        counter: counter,
        title: title,
        tag: 'code',
        value: value,
        text: text
      }
    end

    # [title](url)
    content.scan(/\[(.*?)\]\((.*?)\)/).each do |m|
      next if m[0].start_with?('[')

      value = m[0]
      text = m[1]
      counter += 1
      links << {
        id: id,
        counter: counter,
        title: title,
        tag: 'url',
        value: value,
        text: text
      }
    end
  end

  puts "\nLinks #{links.length}"
  unless links.length.zero?
    links.each do |l|
      puts "* #{l[:filename]} '#{l[:title]}'" if l[:counter] == 1
      puts "  #{l[:counter].to_s.rjust(2, '0')} #{l[:tag]} #{l[:value]}"
    end
  end
  write_csv_file(LINKS_CSV, links)
end

def create_page_item(id, offset)
  pages_id = @pages[id]
  page = pages_id[:page]
  children_ids = pages_id[:children_ids]
  page_id = page['id']
  title = page['page_name']
  body = page['contents']
  if (body.nil? || body.strip.length.zero?) && children_ids.length.positive?
    # rubocop:disable LineLength
    body = '<p><ac:structured-macro ac:name="pagetree" ac:schema-version="1" ac:macro-id="caf6610e-f939-4ef9-b748-2121668fcf46"><ac:parameter ac:name="expandCollapseAll">true</ac:parameter><ac:parameter ac:name="root"><ac:link><ri:page ri:content-title="@self" /></ac:link></ac:parameter><ac:parameter ac:name="searchBox">true</ac:parameter></ac:structured-macro></p>'
    # rubocop:enable LineLength
  end
  title_stripped = title.tr('_', ' ')

  user_id = page['user_id']
  user = @users_assembla.detect { |u| u['id'] == user_id }
  author = user ? user['name'] : ''
  created_at = format_created_at(page['created_at'])

  parent_id = page['parent_id']
  if parent_id
    # Convert Assembla parent_id to Confluence created page id
    parent = @created_pages.detect { |p| p[:page_id] == parent_id }
    if parent
      parent_id = parent[:id]
    else
      puts "Cannot find parent of child id='#{page_id}' title='#{title}' parent_id='#{parent_id}' => set parent_id to nil"
      parent_id = nil
    end
  end

  url = "#{WIKI}/#{title}"

  # Prepend the body with a link to the original Wiki page
  prefix = "<p>Created by #{author} at #{created_at}</p><p><a href=\"#{url}\" target=\"_blank\">Assembla Wiki</a></p><hr/>"

  unless @dry_run
    result, error = confluence_create_page(@space['key'],
                                           title_stripped,
                                           prefix,
                                           body,
                                           parent_id,
                                           @created_pages.length + 1,
                                           @total_wiki_pages)
    @created_pages <<
      if result
        {
          result: error ? 'NOK' : 'OK',
          page_id: page_id,
          id: result['id'],
          offset: offset.join('-'),
          title: title_stripped,
          author: author,
          created_at: created_at,
          body: error ? body : '',
          error: error || ''
        }
      else
        {
          result: 'NOK',
          page_id: page_id,
          id: 0,
          offset: offset.join('-'),
          title: title_stripped,
          author: author,
          created_at: created_at,
          body: body,
          error: error
        }
      end
  end
end

# GET /v1/spaces/:space_id/documents/:id
def get_document_by_id(space_id, id, counter, total)
  document = nil

  pct = percentage(counter, total)
  url = "#{ASSEMBLA_API_HOST}/spaces/#{space_id}/documents/#{id}"
  begin
    result = RestClient::Request.execute(method: :get, url: url, headers: ASSEMBLA_HEADERS)
    document = JSON.parse(result) if result
    puts "#{pct} get_document_by_id() space_id='#{space_id}' GET url=#{url} => OK"
  rescue => e
    puts "#{pct} get_document_by_id() space_id='#{space_id}' GET url=#{url} => NOK error='#{e.inspect}'"
  end
  document
end

@wiki_documents = []

# GET /v1/spaces/[space_id]/documents/[id]/download
def download_item(dir, url_link, counter, total)
  # https://www.assembla.com/spaces/green-in-a-box/documents/bZtyZ4DWqr54hcacwqjQXA/download/bZtyZ4DWqr54hcacwqjQXA
  # https://www.assembla.com//spaces/green-in-a-box/documents/a_NRMANumr5OWBdmr6bg7m/download?filename=blob

  # Strip off the 'download?filename=blob' suffix if present in the link
  url_link.sub!(%r{/download\?.*$}, '')
  id = File.basename(url_link)

  filepath = "#{dir}/#{id}"

  space_id = @assembla_space['id']
  document = get_document_by_id(space_id, id, counter, total)
  if document
    @wiki_documents << document
  else
    puts "Cannot get document with id='#{id}' => RETURN"
    return
  end

  return if File.exist?(filepath)

  pct = percentage(counter, total)
  url = document['url']
  begin
    content = RestClient::Request.execute(method: :get, url: url, headers: ASSEMBLA_HEADERS)
    IO.binwrite(filepath, content)
    puts "#{pct} GET url=#{url} => OK"
  rescue => e
    error_msg = ''
    if e.response
      response = JSON.parse(e.response)
      if response['error'] && response['error_description']
        error_msg = " | #{response['error']}: #{response['error_description']}"
      end
    end
    puts "#{pct} GET url=#{url} => NOK (#{e.message}#{error_msg})"
  end
end

def download_all_images
  total = @all_images.length
  puts "\nDownloading #{total} images" unless total.zero?
  @all_images.each_with_index do |image, index|
    download_item(IMAGES_DIR, image['value'], index + 1, total)
  end
  puts "Done!" unless total.zero?
end

def download_all_documents
  total = @all_documents.length
  puts "\nDownloading #{total} documents"
  @all_documents.each_with_index do |document, index|
    download_item(DOCUMENTS, document['value'], index + 1, total)
  end
  puts "Done!" unless total.zero?
end

def show_all_items(items, verify_proc = nil)
  list_ids = []
  items.each do |item|
    id = item['id']
    list_ids << id unless list_ids.include?(id)
  end
  list_ids.each_with_index do |id, index|
    page = @pages[id][:page]
    @links = items.select { |document| document['id'] == id }
    num = @links.length
    puts "#{index + 1}.0 id=#{id} title='#{page['page_name']}' => #{num} link#{num == 1 ? '' : 's'}"
    @links.each_with_index do |link, ind|
      value = link['value']
      text = link['text']
      padding = ' ' * ((index + 1).to_s.length + 1)
      result = verify_proc.nil? ? '' : " => #{verify_proc.call(value) ? 'OK' : 'NOK'}"
      puts "#{padding}#{ind + 1} value='#{value}' text='#{text}'#{result}"
    end
  end
end

# --- Links --- #
# id,counter,title,tag,value,text
get_all_links
@all_links = csv_to_array(LINKS_CSV)
puts "\n--- Links: #{@all_links.length} ---"

# --- Images --- #
@all_images = @all_links.select { |link| link['tag'] == 'image' }
download_all_images
puts "\n--- Images: #{@all_images.length} ---"
show_all_items(@all_images, ->(value) { File.exist?("#{IMAGES_DIR}/#{File.basename(value)}") })

# --- Anchors (documents + wiki pages) #
@all_anchors = csv_to_array(LINKS_CSV).select { |link| link['tag'] == 'anchor' }.sort_by { |wiki| wiki['value'] }
puts "\n--- Anchors: #{@all_anchors.length} ---"

# --- Documents --- #
@all_documents = @all_anchors.select { |anchor| anchor['value'].match(%r{/documents/}) }
download_all_documents
puts "\n--- Documents: #{@all_documents.length} ---"
show_all_items(@all_documents, ->(value) { File.exist?("#{DOCUMENTS_DIR}/#{File.basename(value)}") })
write_csv_file(WIKI_DOCUMENTS_CSV, @all_documents)

# --- Tickets --- #
@all_tickets = @all_anchors.select { |anchor| anchor['value'].match(%r{/tickets/}) }
# puts "\n--- Tickets: #{@all_tickets.length} ---"
verify_proc = lambda do |value|
  m = value.match(%r{(?:/tickets/|ticket=)(\d+)})
  return false unless m && m[1]

  ticket_nr = m[1]
  @tickets_assembla.detect { |t| t['number'] == ticket_nr }
end
show_all_items(@all_tickets, verify_proc)
write_csv_file(WIKI_TICKETS_CSV, @all_tickets)

# --- Wikis --- #
@all_wikis = @all_anchors.select { |anchor| anchor['value'].match(%r{/wiki/}) }
# puts "\n--- Wikis: #{@all_wikis.length} ---"
verify_proc = lambda do |value|
  page_name = value.match(%r{/([^/]*)$})[1]
  @wiki_assembla.detect { |w| w['page_name'] == page_name }
end
show_all_items(@all_wikis, verify_proc)

# --- Markdowns --- #
@all_markdowns = @all_links.select { |link| link['tag'] == 'markdown' }
@wiki_documents = csv_to_array(WIKI_DOCUMENTS_CSV)
# puts "\n--- All markdowns: #{@all_markdowns.length} ---"
verify_proc = lambda do |value|
  if value.start_with?('image:')
    image = value.sub(/^image:/, '').sub(/\|.*$/, '')
    return File.exist?("#{IMAGES_DIR}/#{image}")
  elsif value.start_with?('url:')
    return true
  elsif value.start_with?('file:')
    file = value.sub(/^file:/, '').sub(/\|.*$/, '')
    return File.exist?("#{DOCUMENTS_DIR}/#{file}")
  else
    return @wiki_assembla.detect { |w| w['page_name'].casecmp(value.tr(' ', '_').sub(/\|.*$/, '')).zero? }
  end
end
show_all_items(@all_markdowns, verify_proc)

@all_codes = @all_links.select { |link| link['tag'] == 'code' }
puts "\n--- Codes: #{@all_codes.length} ---"
show_all_items(@all_codes)

@all_urls = @all_links.select { |link| link['tag'] == 'url' }
puts "\n--- Markdown urls: #{@all_urls.length} ---"
show_all_items(@all_urls)

@pages.each do |id, value|
  parent_id = value[:page]['parent_id']
  next unless parent_id

  parent = @pages[parent_id]
  abort "Cannot find parent page with parent_id='#{parent_id}'" unless parent
  parent[:children_ids] << id
end

# Parent pages sorted by created_at
@parent_pages = @pages.reject { |_, value| value[:page]['parent_id'] }.sort_by { |_, value| value[:page]['created_at'] }
total = @parent_pages.length
puts "\n--- Parents: #{total} ---\n"
@parent_pages.each { |id, _| show_page(id) }
puts "Done!" unless total.zero?

# Child pages sorted by created_at
@child_pages = @pages.select { |_, value| value[:page]['parent_id'] }.sort_by { |_, value| value[:page]['created_at'] }
total = @child_pages.length
puts "\n--- Children: #{total} ---\n"
@child_pages.each { |id, _| show_page(id) }
puts "Done!" unless total.zero?

puts "\n--- Page Tree: #{@pages.length} ---\n"
count = 0
@parent_pages.each do |id, _|
  show_page_tree(id, [count])
  count += 1
end

def upload_all_pages
  puts "\n--- Create pages: #{@total_wiki_pages} ---\n"

  count = 0
  @parent_pages.each do |id, _|
    create_all_pages(id, [count])
    count += 1
  end

  write_csv_file(CREATED_PAGES_CSV, @created_pages)

  # Record failed created pages (NOK), if any
  write_csv_file(CREATED_PAGES_NOK_CSV, @created_pages.select { |page| page[:result] == 'NOK' })
end

# confluence_page_id to wiki_page_id converter
@c_to_w_page_id = {}
@w_to_c_page_id = {}
@c_page_id_to_title = {}

def wiki_page_id_converter
  # result,page_id,id,offset,title,author,created_at,body,error
  csv_to_array(CREATED_PAGES_CSV).each do |page|
    @c_to_w_page_id[page['id']] = page['page_id']
    @w_to_c_page_id[page['page_id']] = page['id']
    @c_page_id_to_title[page['id']] = page['title']
  end
end

def upload_all_images

  puts "\n--- Upload all images ---\n"

  # result, page_id, id, offset, title, author, created_at, body, error
  @created_pages = csv_to_array(CREATED_PAGES_CSV)

  total_images = @all_images.length
  puts "\n--- Upload images: #{total_images} ---\n"

  # id,counter,title,tag,value,text
  @uploaded_images = []
  @all_images.each_with_index do |image, index|
    link_url = image['value']
    basename = File.basename(link_url)
    original_name = 'unknown'
    content_type = 'image/png'

    wiki_documents = csv_to_array(WIKI_DOCUMENTS_CSV)
    msg = "Upload image #{index + 1} basename='#{basename}'"

    # If the '/download?filename=blob' is present in the link we need to match the filename to the
    # original assembla document id which was hopefully saved in the wiki-document-csv log during
    # downloading of all of the attachments.
    m = /download\?filename=(.*)$/.match(basename)
    if m
      filename = m[1]
      found = wiki_documents.detect { |img| img['name'] == filename }
      if found
        basename = found['id']
        content_type = found['content_type']
        original_name = filename
      else
        puts "#{msg} cannot find image filename='#{filename}'"
      end
    else
      found = wiki_documents.detect { |img| img['id'] == basename }
      if found
        content_type = found['content_type']
        original_name = found['name']
      else
        puts "#{msg} cannot find matching image name"
      end
    end

    filepath = "#{IMAGES_DIR}/#{basename}"
    if File.exist?(filepath)
      wiki_image_id = image['id']
      confluence_page = @created_pages.detect { |page| page['page_id'] == wiki_image_id }
      if confluence_page
        confluence_page_id = confluence_page['id']
        c_page_title = @c_page_id_to_title[confluence_page_id]
        puts "#{msg} confluence_page_id=#{confluence_page_id} title='#{c_page_title}' wiki_image_id='#{wiki_image_id}' original_name='#{original_name}'"
        unless @dry_run
          result = confluence_create_attachment(confluence_page_id, filepath, index + 1, total_images)
          confluence_image_id = result ? result['results'][0]['id'] : nil
          @uploaded_images << {
            result: result ? 'OK' : 'NOK',
            confluence_image_id: confluence_image_id,
            wiki_image_id: wiki_image_id,
            basename: basename,
            confluence_page_id: confluence_page_id,
            link_url: link_url
          }
          if result
            confluence_update_attachment(confluence_page_id, confluence_image_id, content_type, index + 1, total_images)
          end
        end
      else
        puts "#{msg} cannot find confluence_id for wiki_id='#{wiki_image_id}'"
      end
    else
      puts "#{msg} cannot find image='#{filepath}'"
    end
  end

  write_csv_file(UPLOADED_IMAGES_CSV, @uploaded_images)
end

def upload_all_documents
  # result, page_id, id, offset, title, author, created_at, body, error
  @created_pages = csv_to_array(CREATED_PAGES_CSV)

  total_documents = @all_documents.length
  puts "\n--- Upload all documents: #{total_documents} ---\n"

  # id,counter,title,tag,value,text
  @uploaded_documents = []
  @all_documents.each_with_index do |document, index|
    link_url = document['value']
    basename = File.basename(link_url)

    wiki_documents = csv_to_array(WIKI_DOCUMENTS_CSV)
    msg = "Upload document #{index + 1} basename='#{basename}'"

    # If the '/download?filename=blob' is present in the link we need to match the filename to the
    # original assembla document id which was hopefully saved in the wiki-document-csv log during
    # downloading of all of the attachments.
    m = /download\?filename=(.*)$/.match(basename)
    original_name = nil
    content_type = nil
    if m
      filename = m[1]
      found = wiki_documents.detect { |img| img['name'] == filename }
      if found
        basename = found['id']
        content_type = found['content_type']
        original_name = filename
      else
        puts "#{msg} cannot find document filename='#{filename}'"
      end
    else
      found = wiki_documents.detect { |img| img['id'] == basename }
      if found
        content_type = found['content_type']
        original_name = found['name']
      else
        puts "#{msg} cannot find matching document name"
      end
    end

    filepath = "#{DOCUMENTS_DIR}/#{basename}"
    if File.exist?(filepath)
      wiki_document_id = document['id']
      confluence_page = @created_pages.detect { |page| page['page_id'] == wiki_document_id }
      if confluence_page
        confluence_page_id = confluence_page['id']
        c_page_title = @c_page_id_to_title[confluence_page_id]
        puts "#{msg} confluence_page_id=#{confluence_page_id} title='#{c_page_title}' wiki_document_id='#{wiki_document_id}' original_name='#{original_name}'"
        unless @dry_run
          result = confluence_create_attachment(confluence_page_id, filepath, index + 1, total_documents)
          confluence_document_id = result ? result['results'][0]['id'] : nil
          @uploaded_documents << {
            result: result ? 'OK' : 'NOK',
            confluence_document_id: confluence_document_id,
            wiki_document_id: wiki_document_id,
            basename: basename,
            confluence_page_id: confluence_page_id,
            link_url: link_url
          }
          if result
            confluence_update_attachment(confluence_page_id, confluence_document_id, content_type, index + 1, total_documents)
          end
        end
      else
        puts "#{msg} cannot find confluence_id for wiki_id='#{wiki_document_id}'"
      end
    else
      puts "#{msg} cannot find document='#{filepath}'"
    end
  end

  write_csv_file(UPLOADED_DOCUMENTS_CSV, @uploaded_documents)
end

# Convert all <img src="link_url" ... > to
# <ac:image ac:height="250"><ri:attachment ri:filename="{image}" ri:version-at-save="1" /></ac:image>
def update_all_image_links

  puts "\n--- Update all image links ---\n"

  unless File.file?(UPLOADED_IMAGES_CSV)
    puts "File '#{UPLOADED_IMAGES_CSV}' does not exist => SKIP"
    return
  end

  confluence_page_ids = {}

  # result,confluence_image_id,wiki_image_id,confluence_page_id,link_url
  @uploaded_images = csv_to_array(UPLOADED_IMAGES_CSV)
  @uploaded_images.each do |image|
    confluence_page_id = image['confluence_page_id']
    confluence_page_ids[confluence_page_id] = [] unless confluence_page_ids[confluence_page_id]
    confluence_image_id = image['confluence_image_id']
    link_url = image['link_url']
    confluence_page_ids[confluence_page_id] << { confluence_image_id: confluence_image_id, link_url: link_url }
  end

  wiki_fixed = csv_to_array(WIKI_FIXED_CSV)

  total = confluence_page_ids.length
  counter = 0
  confluence_page_ids.each do |c_page_id, images|
    counter += 1

    w_page_id = @c_to_w_page_id[c_page_id]
    c_page_title = @c_page_id_to_title[c_page_id]
    msg = "confluence_page_id='#{c_page_id}' title='#{c_page_title}'"

    if w_page_id.nil?
      puts "#{msg} => NOK (unknown w_page_id)"
      next
    end

    msg += " wiki_page_id='#{w_page_id}'"

    # id,page_name,contents,status,version,position,wiki_format,change_comment,parent_id,space_id,user_id,created_at,updated_at
    w_page = wiki_fixed.detect { |page| page['id'] == w_page_id }
    if w_page.nil?
      puts "#{msg} => NOK (unknown w_page)"
      next
    end

    @content = confluence_get_content(c_page_id, counter, total)
    if @content.nil? || @content.strip.length.zero?
      puts "#{msg} content is empty => SKIP"
      next
    elsif images.length.zero?
      puts "#{msg} no images => SKIP"
      next
    end

    puts "#{msg} images=#{images.length} => OK"

    images.each do |image|
      confluence_image_id = image[:confluence_image_id]
      link_url = image[:link_url]
      link_url_escaped = link_url.gsub('?', '\?')
      basename = File.basename(link_url)

      wiki_documents = csv_to_array(WIKI_DOCUMENTS_CSV)

      # If the '/download?filename=blob' is present in the link we need to match the filename to the
      # original assembla document id which was hopefully saved in the wiki-document-csv log during
      # downloading of all of the attachments.
      m = /download\?filename=(.*)$/.match(basename)
      if m
        filename = m[1]
        found = wiki_documents.detect { |img| img['name'] == filename }
        if found
          basename = found['id']
        else
          puts "#{msg} cannot find image filename='#{filename}'"
        end
      end

      # Important: escape any '?', e.g. 'download?filename=blog.png' => 'download\?filename=blog.png'
      if @content.match?(/<img(.*)? src="#{link_url_escaped}"([^>]*?)>/)
        @content.sub!(/<img(.*)? src="#{link_url_escaped}"([^>]*?)>/, "<ac:image ac:height=\"250\"><ri:attachment ri:filename=\"#{basename}\" ri:version-at-save=\"1\" /></ac:image>")
        res = 'OK'
      else
        res = 'NOK'
      end
      puts "* confluence_image_id='#{confluence_image_id}' link_url='#{link_url}' basename='#{basename}' => #{res}"
    end
    confluence_update_page(@space['key'], c_page_id, c_page_title, @content, counter, total) unless @dry_run
  end
end

# Convert all <a href="https://www.assembla.com/spaces/(space)/wiki/(title1)</a> to
# <ac:link><ri:page ri:content-title="(title2)" ri:version-at-save="1" /></ac:link>
# where title2 = title1.tr('_', ' ')
def update_all_page_links

  puts "\n--- Update all page links ---\n"

  confluence_page_ids = {}

  # id,counter,title,tag,value,text
  @all_wikis.each do |wiki|
    wiki_page_id = wiki['id']
    confluence_page_id = @w_to_c_page_id[wiki_page_id]
    confluence_page_ids[confluence_page_id] = [] unless confluence_page_ids[confluence_page_id]
    link_url = wiki['value']
    title = File.basename(link_url).tr('_', ' ')
    confluence_page_ids[confluence_page_id] << { title: title, link_url: link_url }
  end

  total = confluence_page_ids.length
  counter = 0
  confluence_page_ids.each do |c_page_id, pages|
    counter += 1

    c_page_title = @c_page_id_to_title[c_page_id]
    msg = "confluence_page_id='#{c_page_id}' title='#{c_page_title}'"

    @content = confluence_get_content(c_page_id, counter, total)
    if @content.nil? || @content.strip.length.zero?
      puts "#{msg} content is empty => SKIP"
      next
    elsif pages.length.zero?
      puts "#{msg} no pages => SKIP"
      next
    end

    puts "#{msg} => OK"

    pages.each do |page|
      title = page[:title]
      link_url = page[:link_url]
      if @content.match?(%r{<a(.*?)? href="#{link_url}"([^>]*?)>(.*?)</a>})
        @content.sub!(%r{<a(.*?)? href="#{link_url}"([^>]*?)>(.*?)</a>}, "<ac:link><ri:page ri:content-title=\"#{title}\" ri:version-at-save=\"1\" /></ac:link>")
        res = 'OK'
      else
        res = 'NOK'
      end
      puts "* title='#{title}' link_url='#{link_url}' => #{res}"
    end
    confluence_update_page(@space['key'], c_page_id, c_page_title, @content, counter, total) unless @dry_run
  end
end

# Convert all [[page]] to
# <ac:link><ri:page ri:content-title="(title2)" ri:version-at-save="1" /></ac:link>
# where title2 = title1.tr('_', ' ')
def update_all_md_page_links

  puts "\n--- Update all markdown page links ---\n"

  confluence_page_ids = {}

  # result,page_id,id,offset,title,author,created_at,body,error
  created_pages = csv_to_array(CREATED_PAGES_CSV)

  # id,counter,title,tag,value,text
  csv_to_array(LINKS_CSV).select { |link| link['tag'] == 'markdown' }.each do |markdown|
    value = markdown['value']
    next if value.start_with?('image:', 'url:', 'file:', 'snippet:')

    title = value.tr('_', ' ').sub(/\|.*$/, '')
    msg = "value='#{value}' title='#{title}"
    markdown_page_id = markdown['id']
    confluence_page_id = @w_to_c_page_id[markdown_page_id]
    confluence_page_ids[confluence_page_id] = [] unless confluence_page_ids[confluence_page_id]
    found = created_pages.detect { |page| page['result'] == 'OK' && page['title'].casecmp(title).zero? }
    if found
      found_title = found['title']
      if found_title != title
        msg += " found_title='#found_title'"
      end
      puts "#{msg} => OK"
      confluence_page_ids[confluence_page_id] << { value: value, title: found_title, page_id: found['id'] }
    else
      puts "#{msg} => NOK"
    end
  end

  total = confluence_page_ids.length
  counter = 0
  confluence_page_ids.each do |c_page_id, pages|
    counter += 1

    c_page_title = @c_page_id_to_title[c_page_id]
    msg = "confluence_page_id='#{c_page_id}' title='#{c_page_title}'"

    @content = confluence_get_content(c_page_id, counter, total)
    if @content.nil? || @content.strip.length.zero?
      puts "#{msg} content is empty => SKIP"
      next
    elsif pages.length.zero?
      puts "#{msg} no pages => SKIP"
      next
    end

    puts "#{msg} => OK"

    versions = {}
    pages.each do |page|
      version = nil
      value = page[:value]
      title = page[:title]
      page_id = page[:page_id]
      if versions[page_id]
        version = versions[page_id]
      else
        result_get_version = confluence_get_version(page_id)
        if result_get_version
          version = result_get_version['version']['number']
          versions[page_id] = version
        end
      end
      if version
        if @content.match?(/\[\[#{value}\]\]/)
          @content.sub!(/\[\[#{value}\]\]/, "<ac:link><ri:page ri:content-title=\"#{title}\" ri:version-at-save=\"#{version}\" /></ac:link>")
          res = 'OK'
        else
          res = 'NOK'
        end
      else
        res = 'NOK (cannot get version)'
      end
      puts "* value='#{value}' title='#{title}' page_id='#{page_id}' version=#{version} => #{res}"
    end
    confluence_update_page(@space['key'], c_page_id, c_page_title, @content, counter, total) unless @dry_run
  end
end

# Convert all [text](url) to
# <a href="url">text</a>
def update_all_md_url_links

  puts "\n--- Update all markdown url links ---\n"

  unless File.file?(UPLOADED_DOCUMENTS_CSV)
    puts "File '#{UPLOADED_DOCUMENTS_CSV}' does not exist => SKIP"
    return
  end

  confluence_page_ids = {}

  # result,confluence_document_id,wiki_document_id,basename,confluence_page_id,link_url
  uploaded_documents = csv_to_array(UPLOADED_DOCUMENTS_CSV)

  # result,page_id,id,offset,title,author,created_at,body,error
  created_pages = csv_to_array(CREATED_PAGES_CSV)

  # id,counter,title,tag,value,text
  csv_to_array(LINKS_CSV).select { |link| link['tag'] == 'url' }.each do |url|
    value = url['value']
    text = url['text']
    wiki_page_id = url['id']
    confluence_page_id = @w_to_c_page_id[wiki_page_id]
    if confluence_page_id
      confluence_page_ids[confluence_page_id] = [] unless confluence_page_ids[confluence_page_id]
      confluence_page_ids[confluence_page_id] << { value: value, text: text }
    else
      puts "Cannot find confluence_page_id for wiki_page_id='#{wiki_page_id}' => SKIP"
    end
  end

  total = confluence_page_ids.length
  counter = 0
  nok = []
  confluence_page_ids.each do |c_page_id, urls|
    counter += 1

    c_page_title = @c_page_id_to_title[c_page_id]
    msg = "confluence_page_id='#{c_page_id}' title='#{c_page_title}'"

    @content = confluence_get_content(c_page_id, counter, total)
    if @content.nil? || @content.strip.length.zero?
      puts "#{msg} content is empty => SKIP"
      next
    elsif urls.length.zero?
      puts "#{msg} no urls => SKIP"
      next
    end

    puts "#{msg} => #{urls.length}"

    urls.each do |url|
      value = url[:value]
      text = url[:text]
      m = nil
      regexp_error = false
      begin
        m = /\[#{value}\]\(#{text}\)/.match(@content)
      rescue RegexpError => e
        regexp_error = true
      end
      if m
        anchor = nil
        if text.match?(%r{/wiki/})
          title = File.basename(text).tr('_', ' ')
          found = created_pages.detect { |page| page['result'] == 'OK' && page['title'].casecmp(title).zero? }
          if found
            page_id = found['id']
            result_get_version = confluence_get_version(page_id)
            if result_get_version
              version = result_get_version['version']['number']
              found_title = found['title']
              anchor = "<ac:link><ri:page ri:content-title=\"#{found_title}\" ri:version-at-save=\"#{version}\" /></ac:link>"
            else
              puts "Cannot find version for page_id='#{page_id}'"
            end
          else
            puts "Cannot find page with title='#{title}'"
          end
        elsif text.match?(%r{/documents/})
          wiki_document_id = File.basename(text)
          found = uploaded_documents.detect { |document| document['wiki_document_id'] }
          if found
            confluence_document_id = found['confluence_document_id']
            anchor = build_document_link(confluence_document_id)
          else
            puts "Cannot find document with wiki_document_id='#{wiki_document_id}'"
          end
        end
        anchor ||= "<a href=\"#{text}\">#{value}</a>"
        @content.sub!(/\[#{value}\]\(#{text}\)/, anchor)
        # puts "* value='#{value}' text='#{text}' before='#{m[0]}' after='#{anchor}' => OK"
        puts "* value='#{value}' text='#{text}' => OK"
      else
        nok << {
          page_id: c_page_id,
          title: @c_page_id_to_title[c_page_id],
          value: value,
          text: text
        }
        puts "* value='#{value}' text='#{text}' #{regexp_error ? 'regexp error ' : ''}=> NOK"
      end
    end unless @dry_run
    confluence_update_page(@space['key'], c_page_id, c_page_title, @content, counter, total) unless @dry_run
  end

  if nok.length
    puts "Failed urls: #{nok.length}"
    nok.each do |j|
      puts "* page_id='#{j[:page_id]}' title='#{j[:title]}' text='#{j[:value]}' url='#{j[:text]}'"
    end
  end
end

def update_all_document_links
  confluence_page_ids = {}
  total = 0

  puts "\n--- Update all document links: #{total} ---\n"

  unless File.file?(UPLOADED_DOCUMENTS_CSV)
    puts "File '#{UPLOADED_DOCUMENTS_CSV}' does not exist => SKIP"
    return
  end

  # result,confluence_document_id,wiki_document_id,basename,confluence_page_id,link_url
  csv_to_array(UPLOADED_DOCUMENTS_CSV).each do |item|
    next unless item['result'] == 'OK'

    confluence_page_id = item['confluence_page_id']
    confluence_page_ids[confluence_page_id] = [] unless confluence_page_ids[confluence_page_id]
    confluence_page_ids[confluence_page_id] << {
      confluence_document_id: item['confluence_document_id'],
      wiki_document_id: item['wiki_document_id'],
      basename: item['basename'],
      link_url: item['link_url']
    }
    total += 1
  end

  total = confluence_page_ids.length
  counter = 0
  confluence_page_ids.each do |c_page_id, documents|
    counter += 1

    c_page_title = @c_page_id_to_title[c_page_id]
    msg = "confluence_page_id='#{c_page_id}' title='#{c_page_title}'"

    @content = confluence_get_content(c_page_id, counter, total)
    if @content.nil? || @content.strip.length.zero?
      puts "#{msg} content is empty => SKIP"
      next
    elsif documents.length.zero?
      puts "#{msg} no documents => SKIP"
      next
    end

    puts "#{msg} => #{documents.length}"

    documents.each do |document|
      confluence_document_id = document[:confluence_document_id]
      basename = document[:basename]
      link_url = document[:link_url]
      if @content.match?(/#{link_url}/)
        anchor = build_document_link(basename)
        @content.sub!(/#{link_url}/, anchor)
        res = 'OK'
      else
        res = 'NOK'
      end
      puts "* document_id='#{confluence_document_id}' filename='#{basename}' link_url='#{link_url}'"
    end
    confluence_update_page(@space['key'], c_page_id, c_page_title, @content, counter, total) unless @dry_run
  end

  puts "\nIMPORTANT: Update all document links manually by replacing them using insert link attachment\n"
end

def build_document_link(filename)
  # rubocop:disable LineLength
  "<ac:structured-macro ac:name=\"view-file\" ac:schema-version=\"1\" ac:macro-id=\"67cbeb86-e40d-4216-ada2-d20e7e019ccb\"><ac:parameter ac:name=\"name\"><ri:attachment ri:filename=\"#{filename}\" ri:version-at-save=\"1\" /></ac:parameter><ac:parameter ac:name=\"height\">250</ac:parameter></ac:structured-macro>"
  # rubocop:enable LineLength
end

def update_all_ticket_links
  confluence_page_ids = {}
  total = 0
  # id,counter,title,tag,value,text
  csv_to_array(WIKI_TICKETS_CSV).each do |ticket|
    found = nil
    assembla_ticket_nr = nil
    value = ticket['value']
    text = ticket['text']
    m = value.match(%r{(?:/tickets/|ticket=)(\d+)})
    if m && m[1]
      assembla_ticket_nr = m[1]
      found = @tickets_assembla.detect { |t| t['number'] == assembla_ticket_nr }
    end

    jira_issue_key = @assembla_nr_to_jira_key[assembla_ticket_nr]

    result = if assembla_ticket_nr.nil?
               'No match'
             elsif found.nil?
               'Cannot find assembla ticket number'
             elsif jira_issue_key.nil?
               'Cannot find jira issue key'
             else
               'OK'
             end

    confluence_page_id = @w_to_c_page_id[ticket['id']]
    confluence_page_ids[confluence_page_id] = [] unless confluence_page_ids[confluence_page_id]
    confluence_page_ids[confluence_page_id] << {
      result: result,
      value: value,
      text: text,
      assembla_ticket_nr: assembla_ticket_nr,
      jira_issue_key: jira_issue_key
    }
    total += 1
  end

  puts "\n--- Update all ticket links: #{total} ---\n"

  total = confluence_page_ids.length
  counter = 0
  confluence_page_ids.each do |c_page_id, tickets|
    counter += 1

    c_page_title = @c_page_id_to_title[c_page_id]
    msg = "confluence_page_id='#{c_page_id}' title='#{c_page_title}'"

    @content = confluence_get_content(c_page_id, counter, total)
    if @content.nil? || @content.strip.length.zero?
      puts "#{msg} content is empty => SKIP"
      next
    elsif tickets.length.zero?
      puts "#{msg} no pages => SKIP"
      next
    end

    puts "#{msg} => OK"

    tickets.each do |ticket|
      result = ticket[:result]
      value = ticket[:value]
      text = ticket[:text]
      assembla_ticket_nr = ticket[:assembla_ticket_nr]
      jira_issue_key = ticket[:jira_issue_key]
      puts "* value='#{value}' text='#{text}' assembla_ticket_nr='#{assembla_ticket_nr}' jira_issue_key='#{jira_issue_key}' => #{result}"
      next unless result == 'OK'
      if @content.match?(%r{<a(.*?)? href="#{value}"([^>]*?)>#{text}</a>})
        @content.sub!(%r{<a(.*?)? href="#{value}"([^>]*?)>#{text}</a>}, jira_issue_key)
        # @content.sub!(
        #   jira_issue_key,
        #   "<a href=\"https://measurabl.atlassian.net/projects/MP/issues/#{jira_issue_key}\" target=\"_blank\">#{jira_issue_key}</a>"
        # )
        res = 'OK'
      else
        res = 'NOK'
      end
    end
    confluence_update_page(@space['key'], c_page_id, c_page_title, @content, counter, total) unless @dry_run
  end
end

def check_for_regexes (regexes)
  pages = csv_to_array(CREATED_PAGES_CSV)
  total = pages.length
  pages.each_with_index do |page, index|
    page_id = page['id']
    page_title = @c_page_id_to_title[page_id]
    puts "confluence_page_id='#{page_id}' title='#{page_title}'"
    content = confluence_get_content(page_id, index + 1, total)
    regexes.each do |regex|
      content.scan(regex).each do |m|
        puts "* #{m}"
      end
    end

  end
end

def check_for_header_lines
  pages = csv_to_array(CREATED_PAGES_CSV)
  total = pages.length
  pages.each_with_index do |page, index|
    page_id = page['id']
    page_title = @c_page_id_to_title[page_id]
    puts "confluence_page_id='#{page_id}' title='#{page_title}'"
    content = confluence_get_content(page_id, index + 1, total)
    content.each_line do |line|
      puts "* #{line}" if /^#+ /.match?(line)
    end
  end
end

def check_for_tickets
  list = []
  pages = csv_to_array(CREATED_PAGES_CSV)
  total = pages.length
  pages.each_with_index do |page, index|
    page_id = page['id']
    page_title = @c_page_id_to_title[page_id]
    puts "page_id='#{page_id}' title='#{page_title}'"
    content = confluence_get_content(page_id, index + 1, total)
    content.scan(/(?:ticket )?#(\d+)/i).each do |m|
      ticket_nr = m[0]
      issue_key = @assembla_nr_to_jira_key[ticket_nr] || 'unknown'
      puts "* #{ticket_nr} => #{issue_key}"
      list << {
        ticket_nr: ticket_nr,
        issue_key: issue_key,
        page_id: page_id,
        page_title: page_title
      }
    end
  end

  write_csv_file(CHECK_TICKETS_CSV, list)

  # ticket_nr, issue_key, page_id, page_title
  puts "\nUnknown tickets"
  csv_to_array(CHECK_TICKETS_CSV).select { |item| item['issue_key'] == 'unknown' }.each do |item|
    puts "ticket_nr='#{item['ticket_nr']}' page_id='#{item['page_id']}' page_title='#{item['page_title']}'"
  end

  puts "\nSkip tickets"
  csv_to_array(CHECK_TICKETS_CSV).select { |item| item['issue_key'] != 'unknown' && item['ticket_nr'].length < 3 }.each do |item|
    puts "ticket_nr='#{item['ticket_nr']}' issue_key='#{item['issue_key']}' page_id='#{item['page_id']}' page_title='#{item['page_title']}'"
  end

  puts "\nOk tickets"
  page_ids = {}
  csv_to_array(CHECK_TICKETS_CSV).select { |item| item['issue_key'] != 'unknown' && item['ticket_nr'].length > 2 }.each do |item|
    page_id = item['page_id']
    page_title = item['page_title']
    key = "#{page_id}|#{page_title}"
    page_ids[key] = [] unless page_ids[key]
    page_ids[key] << {
      ticket_nr: item['ticket_nr'],
      issue_key: item['issue_key']
    }
    puts "ticket_nr='#{item['ticket_nr']}' issue_key='#{item['issue_key']}' page_id='#{item['page_id']}' page_title='#{item['page_title']}'"
  end

  count = 0
  total_pages = page_ids.length
  page_ids.each do |key, values|
    count += 1
    page_id, page_title = key.split('|')
    total_values = values.length
    content = confluence_get_content(page_id, count, total_pages)
    puts "page_id='#{page_id}' page_title='#{page_title}' => #{total_values}"
    values.each do |value|
      ticket_nr = value[:ticket_nr]
      issue_key = value[:issue_key]
      if content.match?(/##{ticket_nr}/)
        content.sub!(/##{ticket_nr}/, "<a href=\"https://measurabl.atlassian.net/projects/MP/issues/#{issue_key}\">#{issue_key}</a>")
        puts "* #{ticket_nr} => #{issue_key}"
      else
        puts "* #{ticket_nr} => #{issue_key} NOK"
      end
    end
    # Uncomment the following line if you are sure you really want to fix these ticket links.
    # confluence_update_page(@space['key'], page_id, page_title, content, count, total_pages)
  end

end

if @dry_run
  puts
  puts 'IMPORTANT!'
  puts 'Please note that DRY RUN has been enabled'
  puts "For the real McCoy, call this script with 'dry_run=false'"
  puts 'But make sure you are sure!'
  puts
else
  upload_all_pages
  wiki_page_id_converter
  update_all_page_links
  upload_all_images
  update_all_image_links
  update_all_md_page_links
  update_all_md_url_links
  upload_all_documents
  update_all_document_links
  update_all_ticket_links

  # The following lines can be uncommented to run extra checks.
  # check_for_regexes([/#\d+/, /\[.*?\]\(.*?\)/, /<code>.*?<\/code>/])
  # check_for_header_lines
  # check_for_tickets

  puts "\nAll done!\n"
end
