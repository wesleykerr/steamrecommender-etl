require 'logger'
require 'json'
require_relative 'gr_mysql'
require_relative 'game-linker'


def update_steam_games()
  linker = GameLinker.new
  goto_steam(linker)
end

def goto_steamdb(linker)
  uri = URI('http://steamdb.info/api/GetApps.php')
  document = Net::HTTP.get(uri)
  begin 
    json_obj = JSON.parse(document)
    raise "Unsuccessful" unless json_obj['success']
  rescue
    goto_steam(linker)
    return
  end

  app_types = json_obj['data']['AppTypes']
  apps = json_obj['data']['Apps']
  apps.each do |app_hash|
    appid = app_hash['AppID'].to_i
    name = app_hash['Name']
    app_type = app_hash['AppType'].to_i
    if (app_types[app_type] == 'game')
      linker.add_game(appid)
    else
      linker.update_app(appid, name, app_types[app_type])
    end
  end
  linker.flush
end

def goto_steam(linker)
  log = Logger.new(STDOUT)
  log.level = Logger::DEBUG

  api_url = 'http://api.steampowered.com'
  uri = URI("#{api_url}/ISteamApps/GetAppList/v0002/")
  document = Net::HTTP.get(uri)
  apps = JSON.parse(document)["applist"]["apps"].reverse
  apps.each_with_index do |app_hash,index|
    log.debug { "...processed #{index} records" } if index % 500 == 0
    appid = app_hash['appid']
    name = app_hash['name']
    days_old = linker.days_since_updated(appid)
    if days_old > 30
      log.debug { "Appid #{appid} Days: #{days_old}" }
      linker.add_game(appid, name)
    end
  end
  linker.flush
end

update_steam_games

