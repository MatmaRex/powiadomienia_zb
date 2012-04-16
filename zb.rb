# coding: utf-8
require 'sunflower'
require 'pp'
require 'io/console'

# Gets list of all titles of articles with errors reported.
# 
# Ignores incorrectly formatted sections.
def list_of_titles
	p = Page.new 'Wikipedia:Zgłoś błąd w artykule'
	p.code_cleanup # fixes links containing percent-encoding

	text = p.text
	text =~ /== Błędy w plikach ==/
	text = $`||text

	text.scan(/===\s*\[\[:?([^\n\]\|]+)\]\]\s*===/).flatten.map{|a| a.strip.sub(/#.+/, '')}.uniq
end

# Notifies user / wikiproject about error report in articles.
# 
# articles is array of [title, [categories...]]
def notify_user_zb ns, page, articles
	ns_to_talk = {
		'Wikipedysta' => 'Dyskusja wikipedysty',
		'Wikipedystka' => 'Dyskusja wikipedysty',
		'Wikiprojekt' => 'Dyskusja Wikiprojektu',
	}
	
	p = Page.new "#{ns_to_talk[ns]}:#{page}"
	
	header = "== Nowy wpis na Zgłoś błąd =="
	add_header = p.text.scan(/==[^\n]+==/)[-1] != header # jesli ostatni naglowek jest nasz, nie powtarzamy go
	
	signature = "[[Wikipedysta:Powiadomienia ZB|Powiadomienia ZB]] ([[Wikipedia:Zgłoś błąd w artykule/Powiadomienia|informacje]]) ~~"+"~~"+"~"
	
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
	
	summary_links = articles.map{|t,c| "[[Wikipedia:Zgłoś błąd w artykule##{t}|#{t}]]" }.join(', ')
	p.save p.title, "powiadomienie o nowych wpisach na Zgłoś błąd – #{summary_links}"
end

# Returns an array of user/wikiproject notification settings.
# 
# Returns format: array of [ namespace, title, {settings} ]
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
	
	# mapping of magic_character => category_type, used below
	mappings = {
		'!' => :exclude_cats,
		'-' => :nofollow_cats,
		'+' => :include_cats,
		'' => :include_cats, # needed as default
	}
	
	users.map{|u| 
		cats = Page.new(u + "/ZB_config.js").text.strip.gsub(/\uFEFF|\u200E|\u200B/, '').split("\n")
		settings = {
			:include_cats => [],
			:exclude_cats => [],
			:nofollow_cats => [],
		}
		cats.each do |c|
			c.strip!
			# parsing - check if the line starts with a special character, currently one of -+!, and strip it
			# also find out what this character represents
			type = mappings.find{|ch, t| c.sub!(/^#{Regexp.escape ch}/, '') }[-1]
			c.strip!
			# prepend 'Kategoria' if missing
			c = c.start_with?('Kategoria:') ? c : 'Kategoria:'+c
			
			settings[type] << c
		end
		[*u.split(':', 2), settings]
	}
end

class Module
	# Memoize a method with optional cache timeout and ignoring certain arguments.
	def memoize meth, opts
		time, which_args = opts[:time], opts[:args]
		
		aliased = :"_nomemo_#{meth}"
		datastore = :"@_memo_for_#{meth}"
		
		if instance_methods.include? aliased
			warn "trying to rememoize a method; stopping"
			return
		end
		
		alias_method aliased, meth
		
		define_method meth do |*args|
			hh_args = which_args ? args.values_at(*which_args) : args
			
			instance_variable_set(datastore, {}) unless instance_variable_get(datastore)
			hsh = instance_variable_get(datastore)
			if hsh[hh_args] and (time ? hsh[hh_args][0] + time > Time.now : true)
				# pass
			else
				# cache
				hsh[hh_args] = [Time.now, send(aliased, *args)]
			end
			
			hsh[hh_args][1]
		end
	end
end


module Kernel
# Returns a tree of supercategories of given article or category. Gets rid of category cycles.
# 
# Tree and its subtrees have a #walk method, which allows you to traverse the entire graph in depth-first manner,
# and takes a block, yielding category name.
# Throwing :nofollow in #walk's block will stop traversing the branch and resume from the next one.
# 
# Memoized.
# 
# Format:
# 
# 	{
# 		root => {
# 			category1 => {subcat1 => {...} },
# 			category2 => {...},
# 			category3 => {subcat2 => {} },
# 		}
# 	}
def upwards_category_graph root, already=[root]
	begin
		graph = {}
		Timeout::timeout 60*5 do
			# get a list of categories on this page/cat, exclude already found earlier in tree
			res = $s.API 'action=query&prop=categories&cllimit=max&titles='+(CGI.escape root)
			categories = res['query']['pages'].map{|k,v| (v['categories']||[]).map{|v| v['title']} }.flatten.uniq.compact
			categories -= already
			
			# add newly found to the list
			already += categories; already.uniq!
			
			graph[root] = categories.map{|c| upwards_category_graph c, already}
			def graph.walk &block
				self.each do |k, v|
					catch :nofollow do
						block.call k
						# not reached if block throws :nofollow
						v.each{|g| g.walk &block}
					end
				end
			end
		end
	rescue Timeout::Error, Errno::ETIMEDOUT, RestClient::RequestFailed
		puts "Timed out while listing categories for #{root}; retrying..."
		retry
	end
	
	graph
end

memoize :upwards_category_graph, time: 10*60, args: [0]
end






if $0 == __FILE__
	$stdout.sync = $stderr.sync = true
	
	$stderr.puts 'Input password:'
	$s = s = Sunflower.new('pl.wikipedia.org').login('Powiadomienia ZB', STDIN.noecho(&:gets).strip)


	titles, queue, last_seen = *(Marshal.load File.binread 'zb-marshal' rescue [list_of_titles(), [], {}])

	while true
		begin
			new_titles = user_notif_sett = nil
			
			Timeout::timeout 60*5 do
				new_titles = list_of_titles()
				user_notif_sett = get_user_notification_settings()
			end
		rescue Timeout::Error, Errno::ETIMEDOUT, RestClient::RequestFailed
			puts "Timed out while downloading list of titles or user settings; retrying..."
			retry
		end
		
		
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
			cat_graph = upwards_category_graph title
			
			
			user_notif = {}
			
			user_notif_sett.each do |ns, page, settings|
				catch :stop do
					cat_graph.walk do |cat|
						if settings[:include_cats].include? cat
							# add this title to this user's list; add the category to title's list
							user_notif[[ns, page]] ||= {}
							user_notif[[ns, page]][title] ||= []
							user_notif[[ns, page]][title] << cat unless user_notif[[ns, page]][title].include? cat
						elsif settings[:nofollow_cats].include? cat
							# don't go further
							throw :nofollow
						elsif settings[:exclude_cats].include? cat
							# remove this title from user's list, if it was already added; stop processing the graph
							user_notif[[ns, page]].delete title if user_notif[[ns, page]]
							throw :stop
						end
					end
				end
			end
			
			
			user_notif.each do |(ns, page), articles_hash|
				begin
					Timeout::timeout 60*5 do
						puts "Notifying #{ns}:#{page} about #{articles_hash.map{|a| a[0]}.join(', ')}."
						notify_user_zb ns, page, articles_hash
					end
				rescue Timeout::Error, Errno::ETIMEDOUT, RestClient::RequestFailed
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
end

