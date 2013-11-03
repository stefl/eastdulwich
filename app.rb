require 'rubygems'
require 'bundler'  
Bundler.require

require 'mechanize'
require "sinatra"
require "open-uri"
require "nokogiri"
require "json"
require "sanitize"
require 'padrino-helpers'
require 'sinatra/respond_to'
require 'sinatra/asset_pipeline'
require 'sinatra/static_assets'
require 'i18n'
require 'i18n/backend/fallbacks'

class Sanitize
  module Config
    ULTRARELAXED = {
      :elements => [
        'a', 'b', 'blockquote', 'br', 'caption', 'cite', 'code', 'col',
        'colgroup', 'dd', 'dl', 'dt', 'em', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
        'i', 'img', 'li', 'ol', 'p', 'pre', 'q', 'small', 'strike', 'strong',
        'sub', 'sup', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'u',
        'ul', 'object', 'embed', 'param', 'iframe', 'script'],

      :attributes => {
        'a'          => ['href', 'title'],
        'blockquote' => ['cite'],
        'col'        => ['span', 'width'],
        'colgroup'   => ['span', 'width'],
        'img'        => ['align', 'alt', 'height', 'src', 'title', 'width'],
        'ol'         => ['start', 'type'],
        'q'          => ['cite'],
        'table'      => ['summary', 'width'],
        'td'         => ['abbr', 'axis', 'colspan', 'rowspan', 'width'],
        'th'         => ['abbr', 'axis', 'colspan', 'rowspan', 'scope',
                         'width'],
        'ul'         => ['type'],
        'object' => ['width', 'height'],
        'param'  => ['name', 'value'],
        'embed'  => ['src', 'type', 'allowscriptaccess', 'allowfullscreen', 'width', 'height', 'flashvars'],
        'iframe' => ['src', 'width', 'height', 'frameborder'],
        'script' => ['src']
      },

      :protocols => {
        'a'          => {'href' => ['ftp', 'http', 'https', 'mailto', :relative]},
        'blockquote' => {'cite' => ['http', 'https', :relative]},
        'img'        => {'src'  => ['http', 'https', :relative]},
        'q'          => {'cite' => ['http', 'https', :relative]}
      },

      :transformers => lambda { |env| next unless env[:node_name] == 'script'; unless (env[:node]['src'] && env[:node]['src'].include?('http://player.ooyala.com')); Sanitize.clean_node!(env[:node], {}); end; nil }
    }
  end
end

class EastDulwich < Sinatra::Base
  register Sinatra::RespondTo
  register Sinatra::AssetPipeline
  helpers Padrino::Helpers::FormatHelpers

  set :assets_precompile, %w(*.js *.css *.png *.jpg *.svg *.eot *.ttf *.woff)

  enable :sessions
  set :session_secret, ENV["SESSION_KEY"] || 'not strongly encrypted' 
  enable :logging

  configure do
    I18n::Backend::Simple.send(:include, I18n::Backend::Fallbacks)
    I18n.load_path = Dir[File.join(settings.root, 'locales', '*.yml')]
    I18n.backend.load_translations
  end

  helpers do

    def base_host
      @base_host = "http://#{request.host}:#{request.port != 80 ? request.port : ""}"
    end

    def actual_date date_text
      puts date_text
      date = Chronic.parse(date_text)
      if(date > DateTime.now)
        date - 86400
      else
        date
      end
    end

    def parse_content content
      cleaned = Sanitize.clean(content, Sanitize::Config::ULTRARELAXED)
      working = cleaned.lines
      has_quote = false
      puts "PARSE"
      working.each_with_index do |line,i|
        puts line
        puts line.class
        if line =~ /Wrote:/
          puts "has quote"
          working[i] = "<blockquote>#{line}"
          has_quote = true
        elsif has_quote
          if matches = line.match(/&gt; (.+)$/)
            working[i] = matches[1]
          elsif line =~ /---/
            working[i] = "<hr />"
          else
            has_quote = false
            working[i] = "</blockquote>" + line
          end
        end
      end
      cleaned = working.join
      if cleaned.lines.last =~ /Edited [0-9]+ time/
        temp = cleaned.lines
        temp.pop
        cleaned = temp.join + "<p class='edited'>#{cleaned.lines.last}</p>"
      end
      cleaned
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
    original_url = "http://www.eastdulwichforum.co.uk/forum/list.php?#{params[:id]}"
    doc = Nokogiri::HTML(open(original_url).read)
    title = doc.css(".PhorumNavBlock2").first.css("a").last.text
    @forum = {
      original_url: original_url,
      title: title,
      id: params[:id].to_i
    }
    @threads = []
    doc.search("table").first.css("tr").each do |i|
      a_tag = i.css("a")[0]
      if a_tag != nil && !(a_tag.attribute("href").to_s.include?("adserver"))
        puts i.css(a_tag.attribute("href"))
        url = a_tag.attribute("href")
        thread_id = url.to_s.scan(/([0-9]+)$/).flatten[0].to_i
        @threads << {
          :original_url => url,
          :id => thread_id,
          :url => "#{base_host}/forums/#{params[:id]}/threads/#{thread_id}",
          :title => a_tag.text,
          :view_count => i.css("td")[1].text.to_i,
          :posts_count => i.css("td")[2].text.to_i,
          :updated_at => actual_date(i.css("td").last.text.to_s.match(/(^.+PM|^.+AM)/)[1]),
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
      f.json { { forum: @forum, threads: @threads.to_json } }
    end
  end

  get "/forums/:forum_id/threads/:id" do
    original_url = "http://www.eastdulwichforum.co.uk/forum/read.php?#{params[:forum_id]},#{params[:id]}"
    doc = Nokogiri::HTML(open(original_url).read)
    thread = doc.css(".PhorumReadMessageBlock").first
    attachments = thread.css("a").select do |a| 
      a.attribute("href").to_s =~ /\/file\.php/
    end.collect do |attachment| 
      matches = attachment.text.match(/([^\(]+) \(([0-9a-zA-Z\.]+)/)
      {
        url: "/forums/#{params[:forum_id]}/attachments/#{attachment.attribute('href').to_s.split('file=').last.to_i}",
        original_url: attachment.attribute("href").to_s,
        filename: matches[1],
        filesize: matches[2]
      }
    end
    person = thread.css("strong a")
    date_posted = DateTime.parse(thread.css(".PhorumReadBodyHead")[0].text.to_s.split(person.text).last)
    @thread = {
      title: doc.css(".PhorumReadBodySubject")[0].text,
      original_url: original_url,
      forum_id: params[:forum_id].to_i,
      id: params[:id],
      date_posted: date_posted,
      content_html: parse_content(thread.css(".PhorumReadBodyText")[0].inner_html.strip.encode("utf-8")),
      attachments: attachments || [],
      person: {
        nickname: person.text,
        id: person.attribute("href").to_s.scan(/[0-9]+$/).flatten[0].to_i,
        url: person.attribute("href")
      }
    } 
    @posts = []
    @post_ids = doc.css("a").collect {|a| a.attribute("name") }.select {|b| b.to_s =~ /msg/ }.collect {|name| name.to_s.scan(/msg-([0-9]+)/).flatten[0].to_i }
    doc.css(".PhorumReadMessageBlock").each do |i|
      person = i.css(".PhorumReadBodyHead")[1].css("a") rescue nil
      person ||= i.css(".PhorumReadBodySubject")[1].css("a") rescue nil
      date_posted = DateTime.parse(i.css(".PhorumReadBodyHead")[1].text.to_s.split(person.text).last) rescue nil
      post = {
        :title => i.css(".PhorumStdBlock")[0].css("div")[0].text, #css changes if you are logged in
        :id => @post_ids.shift,
        :date_posted => date_posted,
        :content_html => parse_content(i.css(".PhorumReadBodyText")[0].inner_html.strip.encode("utf-8"))
      }
      if person
        post[:person] = {
          :nickname => person.text,
          :id => person.attribute("href").to_s.scan(/[0-9]+$/).flatten[0].to_i,
          :url => person.attribute("href")
        }
      end
      @posts << post
    end
    @posts.shift
    respond_to do |f|
      f.html { haml :'thread' }
      f.json do
        {
          thread: @thread,
          posts: @posts
        }.to_json
      end
    end
  end

  get "/login" do
    haml :'login'
  end

  get "/forums/:forum_id/attachments/:id" do
    result = ""
    remote = open("http://www.eastdulwichforum.co.uk/forum/file.php?#{params[:forum_id]},file=#{params[:id]}") do |proxy|
      content_type proxy.content_type
      result = proxy.read
    end
    result
  end

  get "/cookies" do
    puts "COOKIES"
    puts session[:cookies]
    s = StringIO.new 
    s << session[:cookies]
    s.rewind
    a = Mechanize.new
    a.cookie_jar.load(s, :format => :yaml)
    a.cookie_jar.cookies.to_yaml
  end

  post "/login" do
    a = Mechanize.new
    a.get('http://www.eastdulwichforum.co.uk/forum/login.php?0') do |page|
      page.forms.first do |f|
        f.username  = params[:username]
        f.password         = params[:password]
      end.click_button
    end
    s = StringIO.new()
    a.cookie_jar.save s, :format => :cookiestxt
    s.rewind
    session[:cookies] = s.read
    redirect "/"
  end

  post "/forums/:forum_id/threads/:thread_id/posts/:id/reply" do
    a = Mechanize.new
    a.get("http://www.eastdulwichforum.co.uk/forum/read.php?#{params[:forum_id]},#{params[:thread_id]},#{params[:id]}#REPLY") do |page|
      page.forms.first do |f|
        f.username  = params[:username]
        f.password         = params[:password]
      end.click_button
    end
  end
end