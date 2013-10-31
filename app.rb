require "sinatra"
require "open-uri"
require "nokogiri"
require "json"
require "sanitize"
require 'padrino-helpers'
require 'sinatra/respond_to'

class EastDulwich < Sinatra::Base
  register Sinatra::RespondTo
  helpers do
    def base_host
      @base_host = "http://#{request.host}:#{request.port != 80 ? request.port : ""}"
    end
  end

  get "/" do
    doc = Nokogiri::HTML(open("http://www.eastdulwichforum.co.uk/").read)
    @forums = doc.css(".forum-name").collect do |i| 
      a_tag = i.css("a")
      puts a_tag.inspect
      forum_id = a_tag.attribute("href").to_s.scan(/\?([0-9]+)/).flatten[0].to_i
      {
        :name => a_tag.text.split("...").first, 
        :original_url => a_tag.attribute("href"),
        :url => "#{base_host}/forums/#{forum_id}",
        :id => forum_id
      }
    end
    @forums.shift
    respond_to do |f|
      f.html { haml :'index' }
      f.json { @forms.to_json }
    end
  end

  get "/forums/:id" do
    doc = Nokogiri::HTML(open("http://www.eastdulwichforum.co.uk/forum/list.php?#{params[:id]}").read)
    @posts = []
    doc.search("table").first.css("tr").each do |i|
      a_tag = i.css("a")[0]
      if a_tag != nil && !(a_tag.attribute("href").to_s.include?("adserver"))
        puts i.css(a_tag.attribute("href"))
        url = a_tag.attribute("href")
        post_id = url.to_s.scan(/([0-9]+)$/).flatten[0].to_i
        @threads << {
          :original_url => url,
          :id => post_id,
          :url => "#{base_host}/forums/#{params[:id]}/posts/#{post_id}",
          :title => a_tag.text,
          :view_count => i.css("td")[1].text.to_i,
          :posts_count => i.css("td")[2].text.to_i,
          :person => {
            :nickname => i.css("td")[3].css("a").text.to_s,
            :id => i.css("td")[3].css("a").attribute("href").to_s.scan(/[0-9]+$/).flatten[0].to_i,
            :url => i.css("td")[3].css("a").attribute("href")
          }
        }
      end
    end
    respond_to do |f|
      f.html { haml :'forum' }
      f.json { @threads.to_json }
    end
  end

  get "/forums/:forum_id/posts/:id" do
    doc = Nokogiri::HTML(open("http://www.eastdulwichforum.co.uk/forum/read.php?#{params[:forum_id]},#{params[:id]}").read)
    @posts = []
    @post_ids = doc.css("a").collect {|a| a.attribute("name") }.select {|b| b.to_s =~ /msg/ }.collect {|name| name.to_s.scan(/msg-([0-9]+)/).flatten[0].to_i }
    puts doc.css("a").collect {|a| a.attribute("name") }
    doc.css(".PhorumReadMessageBlock").each do |i|
      person = i.css(".PhorumReadBodyHead")[1].css("a") rescue nil
      person ||= i.css(".PhorumReadBodySubject")[1].css("a") rescue nil
      post = {
        :title => i.css(".PhorumStdBlock")[0].css("div")[0].text, #css changes if you are logged in
        :id => @post_ids.shift,
        :content_html => Sanitize.clean(i.css(".PhorumReadBodyText")[0].inner_html.strip.encode("utf-8"), Sanitize::Config::RELAXED)
      }
      if person
        puts person 
        post[:person] = {
          :nickname => person.text,
          :id => person.attribute("href").to_s.scan(/[0-9]+$/).flatten[0].to_i,
          :url => person.attribute("href")
        }
      end
      @posts << post
    end
    respond_to do |f|
      f.html { haml :'thread' }
      f.json { @posts.to_json }
    end
  end
end