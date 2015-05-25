require 'httparty'
require 'nokogiri'
require 'open-uri'
require 'logger'
require 'damerau-levenshtein'

require 'uri'
require 'net/http'

class GameLinker

  def initialize
    @log = Logger.new(STDOUT)
    @log.level = Logger::DEBUG

    @gb_key = "1bcdfb88180202845adab96300ff82e7ffefe0e9"
    @gb_api = "http://www.giantbomb.com/api"

    @steam = "http://store.steampowered.com/"
    @steam_api = "http://api.steampowered.com/"
    
    @buffer = []
    
    user = ENV['DB_USER'] || 'root'
    password = ENV['DB_PASSWORD'] || ''
    host = ENV['DB_HOST'] || 'localhost'
    @log.debug { "Connecting to database #{host} with user #{user}" }
   
    @db = Database.new(host, user, password) 

    # gather up all of the appids and when they were processed
    @update_hash = {}
    rs = @db.query("select appid,updated_datetime from game_recommender.games")
    rs.each do |row|
      @update_hash[row['appid']] = row['updated_datetime']  
    end
  end

  def get_apps() 
    uri = URI("#{@steam_api}/ISteamApps/GetAppList/v0002/")
    document = Net::HTTP.get(uri)
    apps = JSON.parse(document)["applist"]["apps"]
    apps.each do |app_hash|
      yield app_hash
    end
  end

  def add_game(appid, name)
    @log.debug { "Adding game to buffer #{appid} " }
    @buffer << [appid,name]
    flush if @buffer.size >= 1
  end

  def flush()
    get_app_details(@buffer) unless @buffer.size == 0
    @buffer.clear
    sleep 1
  end

  def get_app_details(app_list)
    @log.debug { "Querying: #{app_list}" }
    apps = app_list.map { |appid,name| appid }.join(',')
    uri = URI("#{@steam}/api/appdetails/?appids=#{apps}")
    @log.info { "Uri: #{uri}" }
    response = Net::HTTP.get(uri)
    if response.nil? 
      sleep 5
      get_app_details(app_list)
      return
    end

    begin 
      @log.info { "Response: #{response}" }
      game_hash = JSON.parse(response)
      @log.info { "Game Hash: #{game_hash}" }
      app_list.each do |appid,name|
        @log.debug { " Results: #{appid} " }
        obj_hash = game_hash["#{appid}"]
        if obj_hash['success'] == true
          app_data = obj_hash['data']
          update_game(appid, app_data)  
          
          if app_data['genres'] 
            app_data['genres'].each do |genre_hash|
              add_genre(app_data['steam_appid'], genre_hash['description'])
            end
          end
        else
          update_app(appid, name, 'unknown') 
          sleep 2
        end
      end 
    rescue JSON::ParserError
     @log.info { "Failed to parse #{response}" } 
    end
  end

  # query the database and find the time when we inserted the information about this
  # app into it.
  # @param appid [Fixnum] the id of the app to check
  def days_since_updated(appid)
    insert_app(appid) unless @update_hash.has_key?(appid)
    last_update = @update_hash[appid]
    return Float::INFINITY unless last_update
    return (Time.now - last_update) / 86400.0
  end

  # Test to see if this appid exists in the database.  
  # @param appid [Fixnum] the appid to check
  # @return if this row exists in the database
  def app_exists?(appid)
    rs = @db.query("select appid from game_recommender.games where appid = #{appid}")
    return nil if rs.size == 0
    return true
  end

  # insert the record into the table
  # @param appid [Fixnum] the app id to add
  def insert_app(appid)
    @db.query("insert into game_recommender.games (appid) values (#{appid})")
  end

  # update the game with the given information
  # @param app_data [Hash] the values to update in the database
  def update_game(appid, app_data)
    @log.debug { "Updating: #{app_data['name']}" }
    sql = "update game_recommender.games set"
    sql << "  title = '#{@db.escape(app_data['name'])}' "
    sql << ", app_type = '#{@db.escape(app_data['type'])}' "
    if app_data['metacritic'] && app_data['metacritic']['url'] && app_data['metacritic']['url'].length > 0
      @log.debug { "   metacritic: #{app_data['metacritic']}" }
      sql << ", metacritic = '#{@db.escape(app_data['metacritic']['url'])}' "
    end
    sql << ", updated_datetime = CURRENT_TIMESTAMP "
    sql << " WHERE appid = #{appid} "
    @log.debug { "Query: #{sql}" }
    @db.query(sql)
  end
  
  # update the game with the given information
  # @param app_data [Hash] the values to update in the database
  def update_app(appid, name, app_type)
    @log.debug { "Updating: #{name}" }
    sql = "INSERT INTO game_recommender.games (appid, title, app_type, updated_datetime) "
    sql << " values (#{appid}, '#{@db.escape(name)}', '#{@db.escape(app_type)}', CURRENT_TIMESTAMP) "
    sql << " ON DUPLICATE KEY UPDATE " 
    sql << "   title = '#{@db.escape(name)}' "
    sql << " , app_type = '#{@db.escape(app_type)}' "
    sql << " , updated_datetime = CURRENT_TIMESTAMP "
    @log.debug { "Query: #{sql}" }
    @db.query(sql)
  end

  # add a link between the genre and the app
  # @param appid [Fixnum] the application to update
  # @param genre [String] the name of the genre to attach
  def add_genre(appid, genre)
    g_name = @db.escape(genre)
    results = @db.query("select id from game_recommender.genres where name = '#{g_name}'") 
    genre_id = -1
    if results.size == 0
      @db.query("insert into game_recommender.genres (name) values ('#{g_name}')")
      genre_id  = db.client.last_id
    else
      genre_id = results.first['genre_id']
    end 
    begin
      @db.query("insert into game_recommender.genre_mappings (game_appid, genre_id) values (#{appid}, #{genre_id})")
    rescue Mysql2::Error
      # the id already exists so there is nothing to do.
    end
  end

  # pull available information from steamdb when we can't find it
  # through other channels
  # @param appid [Fixnum] the application to query
  # @return [Hash] containing the information found in the steamdb page
  def steamdb_app(appid)
    results = {}
    url = URI("http://steamdb.info/app/#{appid}")
    puts url
    doc = Nokogiri::HTML(open(url))
    tables = doc.css('.table > tbody > tr')
    if tables
      tables.each do |element|
        pieces = element.css('td')
        if pieces.size > 1
          data_name = pieces[0].content 
          data_value = pieces[1].content
          results['steam_appid'] = data_value if data_name == 'App ID'
          results['name'] = data_value if data_name == 'Name'
          results['type'] = data_value if data_name == 'App Type'
          if data_name == 'metacritic_fullurl'
            results['metacritic'] = { 'url' => data_value }
          end
        end
      end
    end
    results
  end

  def get_steam_genres(url)
    doc = Nokogiri::HTML(open(URI::encode(url)))
    results = doc.css('.details_block > a')
    genres = results.map do |link|
      if link['href'].include? 'genre'
        link.content
      else
        nil
      end
    end.compact! 
  end

  def search_giantbomb(name)
    encoded = URI::encode(name)
    params = "resources=game&field_list=id,name,site_detail_url"
    uri = URI("#{@gb_api}/search/?api_key=#{@gb_key}&format=json&query=#{encoded}&#{params}")
    @log.debug { "URI: #{uri} " }
    results = Net::HTTP.get(uri)
    result_hash = JSON.parse(results)

    raise "bad results #{results}" unless result_hash['error'] == "OK"
    games = result_hash['results']
    games.each do |game_hash|
      title = game_hash['name']
      game_hash['score'] = DamerauLevenshtein.distance(name, title) / [name.size, title.size].max.to_r
    end 
    games.sort! do |a,b|
      a['score'] <=> b['score']
    end
    games
  end
    
  def get_giantbomb_genres(game_id)
    params = "field_list=genres"
    uri = URI("#{@gb_api}/game/#{game_id}/?api_key=#{@gb_key}&format=json&#{params}")
    @log.debug { "URI: #{uri} " }
    results = Net::HTTP.get(uri)
    result_hash = JSON.parse(results)

    raise "bad results #{results}" unless result_hash['error'] == "OK"
    if result_hash['results'].size > 0
      genres = result_hash['results']['genres']
      return genres.map do |genre|
        genre['name']
      end
    end
    return []
  end

  def search_metacritic(name)
    clean_name = name.gsub(':', '').gsub('-', ' ').gsub(' ', '+')
    search_url = 'http://www.metacritic.com/search/game/'
    url = "#{search_url}#{clean_name}/results"
    @log.debug { "URL: #{url}" }
    doc = Nokogiri::HTML(open(URI::encode(url)))
    results = doc.css('ul.search_results > li')
    titles = results.map do |result|
      # make sure that the game is for PC and not ps2
      platform_obj = result.css('.platform')[0]
      next if platform_obj.content.lstrip.rstrip != 'PC'

      object = result.css('h3.product_title > a')[0]
      url = object['href']
      title = object.content.lstrip.rstrip
      @log.debug { "Name: #{name}:#{name.size} Title: #{title}:#{title.size}" }
      @log.debug { "  Raw Distance: #{DamerauLevenshtein.distance(name,title)}, #{[name.size,title.size].max}" } 
      score = DamerauLevenshtein.distance(name, title) / [name.size, title.size].max.to_f
      [url, title, score]
    end.compact!
    titles.sort! do |a,b|
      a[2] <=> b[2]
    end
    return titles
  end

  def metacritic(appid)
    doc = Nokogiri::HTML(open("#{@steam}#{appid}"))
    metalinks = doc.css('#game_area_metalink a')
    if metalinks.size == 1 
      metalinks[0]['href']
    elsif metalinks.size == 0
      @log.info { "No metalink information for #{appid}" }
      nil
    else 
      @log.warn { "Multiple metalink rows for #{appid}" }
      nil
    end
  end
end


