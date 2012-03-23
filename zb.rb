# coding: utf-8
require 'sunflower'
require 'pp'
require 'io/console'

$stdout.sync = $stderr.sync = true

$stderr.puts 'Input password:'
$s = s = Sunflower.new('pl.wikipedia.org').login('MatmaBot', STDIN.noecho(&:gets).strip)


s.summary = 'powiadomienie o nowych wpisach na Zgłoś błąd (test)'

# Gets list of all titles of articles with errors reported.
# 
# Ignores incorrectly formatted sections.
def list_of_titles
	p = Page.new 'Wikipedia:Zgłoś błąd w artykule'
	p.code_cleanup # fixes links containing percent-encoding

	text = p.text
	text =~ /== Błędy w plikach ==/
	text = $`||text

	text.scan(/===\s*\[\[:?([^\n\]\|]+)\]\]\s*===/).flatten.map{|a| a.strip}.uniq
end

# Notifies user / wikiproject about error report in articles.
# 
# articles is array of [title, [categories...]]
def notify_user_zb ns, page, articles
	ns_to_talk = {
		'Wikipedysta' => 'Dyskusja wikipedysty',
		'Wikiprojekt' => 'Dyskusja Wikiprojektu',
	}
	
	p = Page.new "#{ns_to_talk[ns]}:#{page}"
	
	header = "== Nowy wpis na Zgłoś błąd =="
	add_header = p.text.scan(/==[^\n]+==/)[-1] != header # jesli ostatni naglowek jest nasz, nie powtarzamy go
	
	signature = "[[Wikipedysta:MatmaBot|MatmaBot]] ([[Wikipedia:Zgłoś błąd w artykule/Powiadomienia|informacje]]) ~~"+"~~"+"~"
	
	lines = []
	articles.each do |title, cats|
		line = [
			"Zgłoszono błąd w artykule [[#{title}]]",
			"(kategori#{cats.length>1 ? 'e' : 'a'}: #{cats.map{|c| "[[:#{c}|]]"}.join(", ") })",
			"–",
			"[[Wikipedia:Zgłoś błąd w artykule##{title}|zobacz wpis]]."
		].join ' '
		
		lines << line
	end
	
	p.text.rstrip!
	p.text += "\n\n"
	p.text += header+"\n" if add_header
	p.text += lines.join("\n\n")
	p.text += " "+signature
	
	p.save
end

# Returns an array of user/wikiproject notification settings.
# 
# Returns format: array of [ namespace, title, [categories...] ]
def get_user_notification_settings
	list = $s.make_list 'linkson', 'Wikipedia:Zgłoś błąd w artykule/Powiadomienia'
	list -= ['Wikipedysta:Przykładowy użytkownik']
	
	users = list.select{|a|
		# linki do wikipedystów, ale nie do podstron
		(a.start_with? 'Wikipedysta:' and !a.include? '/') or
		(a.start_with? 'Wikipedystka:' and !a.include? '/') or
		# linki do wikiprojektów, zezwalamy na podstrony
		(a.start_with? 'Wikiprojekt:')
	}
	
	users.map{|u| 
		cats = Page.new(u + "/ZB_config.js").text.strip.gsub(/\uFEFF|\u200E|\u200B/, '').split("\n")
		cats = cats.map{|c| c.start_with?('Kategoria:') ? c : 'Kategoria:'+c}
		[*u.split(':', 2), cats]
	}
end




titles, queue, last_seen = *(Marshal.load File.binread 'zb-marshal' rescue [list_of_titles(), [], {}])

while true
	begin
		new_titles = user_notif_sett = nil
		
		Timeout::timeout 60*5 do
			new_titles = list_of_titles()
			user_notif_sett = get_user_notification_settings()
		end
	rescue Timeout::Error, Errno::ETIMEDOUT
		puts "Timed out while downloading list of titles or user settings; retrying..."
		retry
	end
	
	all_cats = user_notif_sett.map{|a| a.last}.flatten.uniq
	
	
	new_titles.each do |t|
		last_seen[t] = Time.now
	end
	
	queue += (new_titles-titles)
	
	puts "#{Time.now}. %d total reports, %d tracked, %d new, %d users, %d queued." %
		[new_titles.length, last_seen.keys.length, (new_titles-titles).length, user_notif_sett.length, queue.length]
	\
	
	title = queue.shift
	title = queue.shift while title && !new_titles.include?(title)
	
	if title
		begin
			out = []
			
			Timeout::timeout 60*5 do
				p = Page.new title
				if p.pageid and p.pageid!=-1
					categories = [title]
					already = []
					
					until categories.empty?
						res = s.API 'action=query&prop=categories&cllimit=max&titles='+(CGI.escape categories.join('|'))
						categories = res['query']['pages'].map{|k,v| (v['categories']||[]).map{|v| v['title']} }.flatten.uniq.compact
						categories -= already
						
						out += categories.select{|c| all_cats.include? c}
						already += categories; already.uniq!
					end
				end
			end
		rescue Timeout::Error, Errno::ETIMEDOUT
			puts "Timed out while listing categories for #{title}; retrying..."
			retry
		end
		
		title_cats = [[title, out.uniq]]
		
		
		user_notif = {}
		
		title_cats.each do |title, cats|
			user_notif_sett.each do |ns, page, wanted_cats|
				intersect = cats & wanted_cats
				
				if !intersect.empty?
					user_notif[[ns, page]] ||= []
					user_notif[[ns, page]] << [title, intersect]
				end
			end
		end
		
		
		user_notif.each do |(ns, page), articles|
			begin
				Timeout::timeout 60*5 do
					puts "Notifying #{ns}:#{page} about #{articles.map{|a| a[0]}.join(', ')}."
					notify_user_zb ns, page, articles
				end
			rescue Timeout::Error, Errno::ETIMEDOUT
				puts "Timed out; retrying..."
				retry
			end
		end
	end
	
	
	# polacz listy, usun wpisy starsze niz 24h
	titles = (titles+new_titles).uniq
	titles.delete_if{|t| last_seen[t] < Time.now-60*60*24 }
	last_seen.delete_if{|k,v| !titles.include?(k) }
	
	File.binwrite 'zb-marshal', Marshal.dump([titles, queue, last_seen])
	
	sleep 3*60
end



