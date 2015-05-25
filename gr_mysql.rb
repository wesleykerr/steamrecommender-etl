
require 'mysql2'

class Database 

  attr_reader :host
  attr_reader :user_name
  attr_reader :password

  attr_reader :client

  def initialize(a_host, a_user_name, a_password = nil)
    @host = a_host
    @user_name = a_user_name
    @password = a_password
    connect
  end

  def query(query_str)
    results = @client.query(query_str)
    if block_given?
      results.each do |row|
        yield row
      end
    else
      return results
    end
    nil
  end

  def update(query)
    @client.query(query)
  end

  def escape(str) 
    @client.escape(str)
  end

  private
  def connect
    @client = Mysql2::Client.new(:host => host, :username => user_name, :password => password)
  end
end
