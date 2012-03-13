# coding: utf-8
require 'sunflower'
require 'pp'
require 'io/console'

puts 'Input password:'
$s = s = Sunflower.new('pl.wikipedia.org').login('MatmaBot', STDIN.noecho(&:gets).strip)

s.summary = 'powiadomienie o nowych wpisach na Zgłoś błąd (test)'

def list_of_titles
	p = Page.new 'Wikipedia:Zgłoś błąd w artykule'

	text = p.text
	text =~ /== Błędy w plikach ==/
	text = $`||text

	text.scan(/===\s*\[\[:?([^\n\]\|]+)\]\]\s*===/).flatten.map{|a| a.strip}.uniq
end

def notify_user_zb username, articles
	p = Page.new "User talk:#{username}"
	
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

def get_user_notification_settings
	list = $s.make_list 'linkson', 'Wikipedia:Zgłoś błąd w artykule/Powiadomienia'
	users = list.select{|a| a.start_with? 'Wikipedysta:' and !a.include? '/'}.reject{|a| a=='Wikipedysta:Przykładowy użytkownik'}
	
	users.map{|u| 
		cats = Page.new(u + "/ZB_config.js").text.strip.split("\n")
		cats = cats.map{|c| c.start_with?('Kategoria:') ? c : 'Kategoria:'+c}
		[u.sub(/^Wikipedysta:/, ''), cats]
	}
end




titles, queue = *(Marshal.read File.binread 'zb-marshal' rescue [list_of_titles(), []])

while true
	new_titles = list_of_titles()
	user_notif_sett = get_user_notification_settings()
	
	all_cats = user_notif_sett.map{|a| a[1]}.flatten.uniq
	
	queue += (new_titles-titles)
	
	puts "Tick. %d total reports, %d new, %d users, %d queued." %
		[new_titles.length, (new_titles-titles).length, user_notif_sett.length, queue.length]
	\
	
	title = queue.shift
	title = queue.shift while title && !new_titles.include?(title)
	
	if title
		p = Page.new title
		out = []
		if p.pageid and p.pageid!=-1
			categories = [title]
			until categories.empty?
				res = s.API 'action=query&prop=categories&cllimit=max&titles='+(CGI.escape categories.join('|'))
				categories = res['query']['pages'].map{|k,v| (v['categories']||[]).map{|v| v['title']} }.flatten.uniq.compact
				out += categories.select{|c| all_cats.include? c}
			end
		end
			
		title_cats = [[title, out.uniq]]
		
		
		user_notif = {}
		
		title_cats.each do |title, cats|
			user_notif_sett.each do |user, wanted_cats|
				intersect = cats & wanted_cats
				
				if !intersect.empty?
					user_notif[user] ||= []
					user_notif[user] << [title, intersect]
				end
			end
		end
		
		user_notif.each do |user, articles|
			puts "Notifying #{user} about #{articles.map{|a| a[0]}.join(', ')}."
			notify_user_zb user, articles
		end
	end
	
	
	titles = new_titles
	
	File.binwrite 'zb-marshal', Marshal.dump([titles, queue])
	
	sleep 3*60
end



