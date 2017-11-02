require "fumimi/version"
require "danbooru/resource"

require "danbooru"
require "danbooru/model"
require "danbooru/comment"
require "danbooru/forum_post"
require "danbooru/post"
require "danbooru/tag"
require "danbooru/wiki"
require "bq"

require "active_support"
require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/numeric/conversions"
require "active_support/core_ext/numeric/time"
require "discordrb"
require "dotenv"
require "pg"
require "pry"
require "pry-byebug"
require "sequel"

Dotenv.load

DB = Sequel.sqlite
Post = DB["danbooru-data.danbooru.posts".to_sym]
PostTags = DB["robot-maid-fumimi.danbooru.post_tags".to_sym]
PostVersionFlat = DB["danbooru-1343.danbooru_production.post_versions_flat_part".to_sym]

module Fumimi::Events
  def do_post_id(event)
    post_ids = event.text.scan(/post #[0-9]+/i).grep(/([0-9]+)/) { $1.to_i }

    post_ids.each do |post_id|
      post = booru.posts.show(post_id)

      event.channel.send_embed do |embed|
        embed_post(embed, event.channel.name, post)
      end
    end

    nil
  end

  def do_forum_id(event)
    forum_post_ids = event.text.scan(/forum #[0-9]+/i).grep(/([0-9]+)/) { $1.to_i }

    forum_post_ids.each do |forum_post_id|
      forum_post = booru.forum_posts.show(forum_post_id)

      topic_ids = [forum_post.topic_id].join(",")
      forum_topics = booru.forum_topics.search(id: topic_ids).group_by(&:id).transform_values(&:first)

      creator_ids = [forum_post.creator_id].join(",")
      users = booru.users.search(id: creator_ids).group_by(&:id).transform_values(&:first)

      event.channel.send_embed do |embed|
        embed_forum_post(embed, forum_post, forum_topics, users)
      end
    end

    nil
  end

  def do_wiki_link(event)
    titles = event.text.scan(/\[\[ ( [^\]]+ ) \]\]/x).flatten

    titles.each do |title|
      render_wiki(event, title.tr(" ", "_"))
    end

    nil
  end

  def do_issue_id(event)
    issue_ids = event.text.scan(/issue #[0-9]+/i).grep(/([0-9]+)/) { $1.to_i }

    issue_ids.each do |issue_id|
      event.send_message "https://github.com/r888888888/danbooru/issues/#{issue_id}"
    end

    nil
  end
end

module Fumimi::Commands
  def do_hi(event, *args)
    event.send_message "Command received. Deleting all animes."; sleep 1

    event.send_message "5..."; sleep 1
    event.send_message "4..."; sleep 1
    event.send_message "3..."; sleep 1
    event.send_message "2..."; sleep 1
    event.send_message "1..."; sleep 1

    event.send_message "Done! Animes deleted."
  end

  def do_say(event, *args)
    return unless event.user.id == 310167383912349697

    channel_name = args.shift
    message = args.join(" ")

    channels[channel_name].send_message(message)
  end

  def do_random(event, *tags)
    post = booru.posts.index(random: 1, limit: 1, tags: tags.join(" ")).first

    event.channel.send_embed do |embed|
      embed_post(embed, event.channel.name, post)
    end
  end

  def do_posts(event, *tags)
    limit = tags.grep(/limit:(\d+)/i) { $1.to_i }.first
    limit ||= 3 
    limit = [10, limit].min

    tags = tags.grep_v(/limit:(\d+)/i)
    posts = booru.posts.index(limit: limit, tags: tags.join(" "))

    posts.each do |post|
      event.channel.send_embed do |embed|
        embed_post(embed, event.channel.name, post)
      end
    end

    nil
  end

  def do_count(event, *tags)
    event.channel.start_typing

    query = (tags + ["id:>-#{rand(2**32)}"]).join(" ")
    resp = booru.counts.show("?tags=#{query}")

    event << "#{tags.join(" ")}: #{resp.counts["posts"]} posts"
  end

  def do_iqdb(event, *urls)
    url = urls.first or return

    event.channel.start_typing
    iqdb_queries = booru.iqdb.index(url: url)

    iqdb_queries.map(&:post).each do |post|
      event.channel.send_embed do |embed|
        embed_post(embed, event.channel.name, post)
      end
    end

    nil
  end

  def do_forum(event, *args)
    event.channel.start_typing

    limit = args.grep(/limit:(\d+)/i) { $1.to_i }.first
    limit ||= 3 
    limit = [10, limit].min
    body = args.grep_v(/limit:(\d+)/i).join(" ")

    # XXX
    forum_posts = booru.forum_posts.search(body_matches: body).take(limit)

    creator_ids = forum_posts.map(&:creator_id).join(",")
    users = booru.users.search(id: creator_ids).group_by(&:id).transform_values(&:first)

    topic_ids = forum_posts.map(&:topic_id).join(",")
    forum_topics = booru.forum_topics.search(id: topic_ids).group_by(&:id).transform_values(&:first)

    forum_posts.each do |forum_post|
      event.channel.send_embed do |embed|
        embed_forum_post(embed, forum_post, forum_topics, users)
      end
    end

    nil
  end

  def do_comments(event, *tags)
    limit = tags.grep(/limit:(\d+)/i) { $1.to_i }.first
    limit ||= 3 
    limit = [10, limit].min
    tags = tags.grep_v(/limit:(\d+)/i)

    # XXX
    comments = booru.comments.search(post_tags_match: tags.join(" ")).take(limit)

    creator_ids = comments.map(&:creator_id).join(",")
    users = booru.users.search(id: creator_ids).group_by(&:id).transform_values(&:first)

    post_ids = comments.map(&:post_id).join(",")
    posts = booru.posts.index(tags: "status:any id:#{post_ids}").group_by(&:id).transform_values(&:first)

    comments.each do |comment|
      event.channel.send_embed do |embed|
        embed_comment(embed, event.channel.name, comment, users, posts)
      end
    end

    nil
  end

  def do_sql(event, *args)
    return unless event.user.id == 310167383912349697

    show_loading_message(event)

    sql = args.join(" ")
    @pg = PG::Connection.open(dbname: "danbooru2")
    results = @pg.exec(sql)

    table = format_table(results.fields, results.map(&:values))

    event << "```"
    event << table.to_s
    event << "#{table.rows.size} of #{results.ntuples} rows"
    event << "```"
  rescue StandardError => e
    event.drain
    event << "Exception: #{e.to_s}.\n"
    event << "https://i.imgur.com/0CsFWP3.png"
  end

  def do_top(event, *args)
    raise ArgumentError unless args.join(" ") =~ /^(tags|taggers|uploaders) in last (day|week|month|year)$/i
    show_loading_message(event)

    period = case args[3]
      when "year"  then "INTERVAL 365 DAY"
      when "month" then "INTERVAL 30 DAY"
      when "week"  then "INTERVAL 7 DAY"
      else "INTERVAL 1 DAY"
    end

    if args[0] == "uploaders"
      query = <<-SQL
        SELECT
          updater_id AS uploader_id,
          COUNT(DISTINCT post_id) as uploads
        FROM `post_versions_flat_part`
        WHERE
          updated_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP, #{period})
          AND version = 1
        GROUP BY updater_id
        ORDER BY uploads DESC
        LIMIT 20;
      SQL

      results = bq.query(query).resolve_user_ids!(booru)
      event << results.to_table("Top Uploaders in Last #{args[3].capitalize}")
    elsif args[0] == "taggers"
      query = <<-SQL
        SELECT
          updater_id AS user_id,
          COUNTIF(added_tag IS NOT NULL) as tags_added,
          COUNTIF(removed_tag IS NOT NULL) as tags_removed,
          COUNT(DISTINCT post_id) AS posts_edited,
          COUNTIF(added_tag IS NOT NULL OR removed_tag IS NOT NULL) AS total_tags
        FROM `post_versions_flat_part`
        WHERE
          updated_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP, #{period})
          AND version > 1
        GROUP BY updater_id
        ORDER BY 5 DESC
        LIMIT 20;
      SQL

      results = bq.query(query).resolve_user_ids!(booru)
      event << results.to_table("Top Taggers in Last #{args[3].capitalize} (excluding tags on uploads)")
    elsif args[0] == "tags"
      cutoff = case args[3]
        when "day"   then 1.0
        when "week"  then 2.0
        when "month" then 3.0
        else 20.0
      end

      query = <<-SQL
        WITH
          added_tag_counts AS (
            SELECT added_tag AS tag, COUNT(*) AS added
            FROM `post_versions_flat_part`
            WHERE updated_at BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP, #{period}) AND CURRENT_TIMESTAMP
            GROUP BY added_tag
          ),
          removed_tag_counts AS (
            SELECT removed_tag AS tag, COUNT(*) AS removed
            FROM `post_versions_flat_part`
            WHERE updated_at BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP, #{period}) AND CURRENT_TIMESTAMP
            GROUP BY removed_tag
          ),
          total_tag_counts AS (
            SELECT COALESCE(added_tag, removed_tag) AS tag, COUNTIF(added_tag IS NOT NULL) - COUNTIF(removed_tag IS NOT NULL) AS count
            FROM `post_versions_flat_part`
            GROUP BY COALESCE(added_tag, removed_tag)
          ),
          tag_stats AS (
            SELECT
              atc.tag AS tag,
              (CASE WHEN category = 0 THEN 'general' WHEN category = 1 THEN 'artist' WHEN category = 3 THEN 'copyright' WHEN category = 4 THEN 'character' ELSE 'unknown' END) AS category_name,
              COALESCE(added, 0) AS added,
              COALESCE(removed, 0) AS removed,
              COALESCE(ttc.count, 0) AS count
            FROM added_tag_counts atc
            LEFT OUTER JOIN removed_tag_counts rtc ON rtc.tag = atc.tag
            LEFT OUTER JOIN total_tag_counts ttc ON atc.tag = ttc.tag
            LEFT OUTER JOIN `tags` AS tags ON atc.tag = tags.name
          )
        SELECT
          tag,
          category_name,
          -- added,
          -- removed,
          added - removed AS net_change
          -- count AS total_count,
          -- ROUND(SAFE_DIVIDE(count, (count - (added - removed))) * 100 - 100, 1) AS percentage_change --- XXX safe divide returns NULLs instead of infinity, which sorts last.
        FROM tag_stats
        WHERE
          NOT REGEXP_CONTAINS(tag, '^(source|parent):')
          -- AND category_name = 'general'
          -- AND count - (added - removed) == 0 -- include only new tags
          AND ABS(ROUND(IEEE_DIVIDE(count, (count - (added - removed))) * 100 - 100, 1)) > #{cutoff} -- exclude large tags
        ORDER BY
          ABS(net_change) DESC
          -- percentage_change DESC
        LIMIT 200;
      SQL

      results = bq.query(query)
      event << results.to_table("Top Tags in Last #{args[3].capitalize} (cutoff: >#{cutoff}% net change)")
    end
  #rescue ArgumentError => e
  #  event.drain
  #  event << "Usage:\n"
  #  event << "`/top uploaders in last <day|week|month|year>`"
  #  event << "`/top taggers in last <day|week|month|year>`"
  #  event << "`/top tags in last <day|week|month|year>`"
  rescue StandardError => e
    event.drain
    event << "Exception: #{e.to_s}.\n"
    event << "https://i.imgur.com/0CsFWP3.png"
  end

  def do_bq(event, *args)
    query = args.join(" ")

    show_loading_message(event)
    event << bq.query(query).to_table
  rescue StandardError => e
    event.drain
    event << "Exception: #{e.to_s}.\n"
    event << "https://i.imgur.com/0CsFWP3.png"
  end

  def do_search(event, *args)
    show_loading_message(event)
    tags = args

    posts = Post.select(:id).reverse(:id)
    tags.each do |tag|
      posts = posts.where(id: PostTags.select(:post_id).where(name: tag))
    end

    results = bq.query(posts.sql, max: 800)
    post_ids = results.take(800).flat_map(&:values).join(",")

    event << "#{tags}: 0 - #{post_ids.size} of #{results.total} posts"
    event << "https://danbooru.donmai.us/posts?tags=id:#{post_ids}"
  rescue StandardError, RestClient::Exception => e
    event.drain
    event << "Exception: #{e.to_s}.\n"
    event << "https://i.imgur.com/0CsFWP3.png"
  end

  def do_user(event, *args)
    raise ArgumentError unless args.size == 1
    show_loading_message(event)

    username = args[0]
    user_id = booru.users.search(name: username).first.try(:id) or raise ArgumentError, "invalid username"

    query = <<-SQL
      WITH
        added_tags AS (
          SELECT
            added_tag AS tag,
            COUNT(*) AS added
          FROM `post_versions_flat_part`
          WHERE
            updater_id = #{user_id}
            AND added_tag IS NOT NULL
            AND NOT REGEXP_CONTAINS(added_tag, '^(source|parent):')
          GROUP BY added_tag
        ),
        removed_tags AS (
          SELECT
            removed_tag AS tag,
            COUNT(*) AS removed
          FROM `post_versions_flat_part`
          WHERE
            updater_id = #{user_id} 
            AND removed_tag IS NOT NULL
            AND NOT REGEXP_CONTAINS(removed_tag, '^(source|parent):')
          GROUP BY removed_tag
        )

      SELECT
        added_tags.tag,
        added,
        removed,
        added + removed AS total
      FROM added_tags
      LEFT OUTER JOIN removed_tags ON added_tags.tag = removed_tags.tag
      ORDER BY 4 DESC;
    SQL

    results = bq.query(query).resolve_user_ids!(booru)
    event << results.to_table("Top Tags Used by #{username}")
  rescue StandardError, RestClient::Exception => e
    event.drain
    event << "Exception: #{e.to_s}.\n"
    event << "https://i.imgur.com/0CsFWP3.png"
  end

  def do_tag(event, *args)
    show_loading_message(event)

    tag = args[0].gsub(/'/, "\\'")

    query = <<-SQL
      SELECT
        added_tag AS tag, category_name AS type, count, updater_id AS creator_id, updated_at AS created_at, post_id
      FROM `post_versions_flat_part` AS pv
      JOIN `robot-maid-fumimi.danbooru.tags` AS t ON pv.added_tag = t.name
      WHERE added_tag = '#{tag}'
      ORDER BY updated_at ASC
      LIMIT 1;
    SQL

    results = bq.query(query).resolve_user_ids!(booru)
    event.send_message(results.to_table("Creator of '#{tag}'"))

    query = <<-SQL
      SELECT
        updater_id,
        COUNTIF(added_tag = '#{tag}') AS added_count,
        COUNTIF(removed_tag = '#{tag}') AS removed_count,
        COUNTIF(added_tag = '#{tag}' OR removed_tag = '#{tag}') AS total_count
      FROM
        `post_versions_flat_part`
      WHERE
        added_tag = '#{tag}' OR removed_tag = '#{tag}'
      GROUP BY updater_id
      ORDER BY 4 DESC
      LIMIT 10;
    SQL

    results = bq.query(query).resolve_user_ids!(booru)
    event.send_message(results.to_table("'#{tag}' Usage By User"))

    query = <<-SQL
      SELECT
        EXTRACT(year FROM updated_at) AS year,
        COUNTIF(added_tag = '#{tag}') AS added_count,
        COUNTIF(removed_tag = '#{tag}') AS removed_count,
        COUNTIF(added_tag = '#{tag}' OR removed_tag = '#{tag}') AS total_count
      FROM
        `post_versions_flat_part`
      WHERE
        added_tag = '#{tag}' OR removed_tag = '#{tag}'
      GROUP BY year
      ORDER BY 1 ASC;
    SQL

    event.send_message bq.query(query).to_table("'#{tag}' Usage By Year")
  rescue StandardError, RestClient::Exception => e
    event.drain
    event << "Exception: #{e.to_s}.\n"
    event << "https://i.imgur.com/0CsFWP3.png"
  end

  def do_stats(event, *args)
    if args == %w[longest tags]
      query = "SELECT name FROM `tags` AS t WHERE t.count > 0 ORDER BY LENGTH(t.name) DESC LIMIT 20"
    elsif args.size == 4 && args[1..2] == %w[created by]
      username = args[3]
      user = booru.users.search(name: username).first

      case args[0]
      when "gentags" then categories = [0]
      when "arttags" then categories = [1]
      when "chartags" then categories = [4]
      when "copytags" then categories = [3]
      when "tags" then categories = [0, 1, 3, 4]
      else categories = [0, 1, 3, 4]
      end

      query = <<-SQL
        WITH
          initial_tags AS (
            SELECT
              added_tag,
              MIN(updated_at) AS updated_at
            FROM
              `post_versions_flat_part`
            GROUP BY
              added_tag
          )
        SELECT
          DISTINCT it.added_tag,
          t.count
        FROM `post_versions` AS pv
        JOIN initial_tags AS it ON pv.updated_at = it.updated_at
        LEFT OUTER JOIN `tags` AS t ON t.name = added_tag
        WHERE
          TRUE
          AND NOT REGEXP_CONTAINS(added_tag, '^source:|parent:')
          AND pv.updater_id = #{user.id}
          AND t.category IN (#{categories.join(",")})
        ORDER BY count DESC
        LIMIT 50;
      SQL
    else
      event << "Usage:\n"
      event << "`/stats longest tags`"
      event << "`/stats tags created by <username>`"
      event << "`/stats gentags created by <username>`"
      event << "`/stats arttags created by <username>`"
      event << "`/stats chartags created by <username>`"
      event << "`/stats copytags created by <username>`"
      return
    end

    show_loading_message(event)
    event << bq.query(query).to_table
  rescue StandardError => e
    event.drain
    event << "Exception: #{e.to_s}.\n"
    event << "https://i.imgur.com/0CsFWP3.png"
  end

protected
  def show_loading_message(event)
    event.respond "*Fumimi is preparing. Please wait warmly until she is ready. This may take up to 30 seconds.*"
    event.channel.start_typing
  end
end

class Fumimi
  include Fumimi::Commands
  include Fumimi::Events

  attr_reader :server_id, :client_id, :token, :log
  attr_reader :bot, :server, :booru, :bq
  attr_reader :initiate_shutdown

  def initialize(server_id:, client_id:, token:, log: Logger.new(STDERR))
    @server_id = server_id
    @client_id = client_id
    @token = token
    @log = RestClient.log = log

    @booru = Danbooru.new
    @bq = BQ.new(booru: @booru, project: "danbooru-1343", dataset: "danbooru_production")
  end

  def server
    bot.servers.fetch(@server_id)
  end

  def channels
    server.channels.group_by(&:name).transform_values(&:first)
  end

  def shutdown!
    log.info("Shutting down...")
    bot.stop
    exit(0)
  end

  def register_commands
    log.debug("Registering bot commands...")

    bot.message(contains: /post #[0-9]+/i, &method(:do_post_id))
    bot.message(contains: /forum #[0-9]+/i, &method(:do_forum_id))
    bot.message(contains: /issue #[0-9]+/i, &method(:do_issue_id))
    bot.message(contains: /\[\[ [^\]]+ \]\]/x, &method(:do_wiki_link))

    bot.command(:hi, description: "Say hi to Fumimi: `/hi`", &method(:do_hi))
    bot.command(:posts, description: "List posts: `/posts <tags>`", &method(:do_posts))
    bot.command(:count, description: "Count posts: `/count <tags>`", &method(:do_count))
    bot.command(:iqdb, description: "Find similar posts: `/iqdb <url>`", &method(:do_iqdb))
    bot.command(:comments, description: "List comments: `/comments <tags>`", &method(:do_comments))
    bot.command(:forum, description: "List forum posts: `/forum <text>`", &method(:do_forum))
    bot.command(:random, description: "Show a random post: `/random <tags>`", &method(:do_random))
    bot.command(:stats, description: "Query various stats: `/stats help`", &method(:do_stats))
    bot.command(:tag, description: "Show tag information: `/tag <name>`", &method(:do_tag))
    bot.command(:user, description: "Show information about user: `/user <name>`", &method(:do_user))
    bot.command(:search, description: "Search posts on BigQuery: `/search <tags>`", &method(:do_search))
    bot.command(:bq, description: "Run a query on BigQuery: `/bq <query>`", &method(:do_bq))
    bot.command(:top, description: "Show leaderboards: `/top help`", &method(:do_top))
    bot.command(:sql, help_available: false, &method(:do_sql))
    bot.command(:say, help_available: false, &method(:do_say))
  end

  def embed_post(embed, channel_name, post, tags = nil)
    embed.author = Discordrb::Webhooks::EmbedAuthor.new({
      name: "@#{post.uploader_name}",
      url: "https://danbooru.donmai.us/users?name=#{CGI::escape(post.uploader_name)}"
    })

    embed.title = "post ##{post.id}"
    embed.url = post.url
    embed.image = post.embed_image(channel_name)
    embed.color = post.border_color

    embed.footer = post.embed_footer

    embed

=begin
    chartags = tags.select { |t| t.category == 4 }.sort_by(&:post_count).reverse.take(1).map do |tag|
      p = tag.name.tr("_", " ").gsub(/\]/, "\]")
      t = CGI::escape(tag.name)
      "[#{p}](https://danbooru.donmai.us/posts?tags=#{t})"
    end.join(", ")

    copytags = tags.select { |t| t.category == 3 }.sort_by(&:post_count).reverse.take(1).map do |tag|
      p = tag.name.tr("_", " ").gsub(/\]/, "\]")
      t = CGI::escape(tag.name)
      "[#{p}](https://danbooru.donmai.us/posts?tags=#{t})"
    end.join(", ")

    arttags = tags.select { |t| t.category == 1 }.sort_by(&:post_count).reverse.take(1).map do |tag|
      p = tag.name.tr("_", " ").gsub(/\]/, "\]")
      t = CGI::escape(tag.name)
      "[#{p}](https://danbooru.donmai.us/posts?tags=#{t})"
    end.join(", ")

    gentags = tags.select { |t| t.category == 0 }.sort_by(&:post_count).take(10).map do |tag|
      p = tag.name.tr("_", " ").tr("]", "\]")
      t = CGI::escape(tag.name)
      "[#{p}](https://danbooru.donmai.us/posts?tags=#{t})"
    end.join(", ")
=end
  end

  def embed_comment(embed, channel_name, comment, users, posts)
    user = users[comment.creator_id]
    post = posts[comment.post_id]

    embed.title = "@#{user.name}"
    embed.url = "https://danbooru.donmai.us/users?name=#{user.name}"

    embed.author = Discordrb::Webhooks::EmbedAuthor.new({
      name: post.shortlink,
      url: post.url,
    })

    embed.description = comment.pretty_body

    #embed.image = post.embed_image(event)
    embed.thumbnail = post.embed_thumbnail(channel_name)
    embed.footer = comment.embed_footer
  end

  def embed_forum_post(embed, forum_post, forum_topics, users)
    user = users[forum_post.creator_id]
    topic = forum_topics[forum_post.topic_id]

    embed.author = Discordrb::Webhooks::EmbedAuthor.new({
      name: "#{topic.title} (forum ##{forum_post.id})",
      url: "https://danbooru.donmai.us/forum_posts/#{forum_post.id}"
    })

    embed.title = "@#{user.name}"
    embed.url = "https://danbooru.donmai.us/users?name=#{user.name}"

    embed.description = forum_post.pretty_body
    embed.footer = forum_post.embed_footer
  end

  def render_wiki(event, title)
    event.channel.start_typing

    wiki = booru.wiki.index(title: title).first
    tag  = booru.tags.search(name: title).first

    if tag && tag.post_count > 0
      post = tag.example_post(booru)
    end

    event.channel.send_embed do |embed|
      embed.author = Discordrb::Webhooks::EmbedAuthor.new({
        name: title.tr("_", " "),
        url: "https://danbooru.donmai.us/wiki_pages/#{title}"
      })

      embed.description = wiki.try(:pretty_body)

      if post
        embed.title = "post ##{post.id}"
        embed.url = "https://danbooru.donmai.us/posts/#{post.id}"
        embed.image = post.embed_image(event.channel.name)
      end
    end
  end

  def run_commands
    log.debug("Starting bot...")

    @bot = Discordrb::Commands::CommandBot.new({
      name: "Robot Maid Fumimi",
      client_id: client_id,
      token: token,
      prefix: '/',
    })

    register_commands
    bot.run(:async)

    loop do
      shutdown! if initiate_shutdown
      sleep 1
    end
  end

  def run_feeds(comment_feed: "", upload_feed: "", forum_feed: "", error_channel: "")
    log.debug("Entering feed update loop...")

    @bot = Discordrb::Bot.new({
      name: "Robot Maid Fumimi",
      client_id: client_id,
      token: token,
    })

    bot.run(:async)

    last_upload_time = Time.now
    last_comment_time = Time.now
    last_forum_post_time = Time.now

    loop do
      last_upload_time = update_uploads_feed(last_upload_time, channels[upload_feed])
      last_comment_time = update_comments_feed(last_comment_time, channels[comment_feed])
      last_forum_post_time = update_forum_feed(last_forum_post_time, channels[forum_feed])

      sleep 30
    end
  rescue StandardError => e
    msg =  "Error. Retrying in 60s...\n\n"
    msg += "Exception: #{e.to_s}.\n"
    msg += "https://i.imgur.com/0CsFWP3.png"

    bot.send_message(channels[error_channel], msg)

    sleep 60
    retry
  end

  def update_uploads_feed(last_checked_at, channel)
    log.debug("Checking /posts (last seen: #{last_checked_at}).")

    posts = booru.posts.newest(last_checked_at, 50).reverse

    posts.each do |post|
      channel.send_embed do |embed|
        embed_post(embed, channel.name, post)
      end
    end

    posts.last&.created_at || last_checked_at
  end

  def update_comments_feed(last_checked_at, channel)
    log.debug("Checking /comments (last seen: #{last_checked_at}).")

    comments = booru.comments.newest(last_checked_at, 50).reverse
    comments = comments.reject(&:do_not_bump_post)

    creator_ids = comments.map(&:creator_id).join(",")
    users = booru.users.search(id: creator_ids).group_by(&:id).transform_values(&:first)

    post_ids = comments.map(&:post_id).join(",")
    posts = booru.posts.index(tags: "status:any id:#{post_ids}").group_by(&:id).transform_values(&:first)

    comments.each do |comment|
      channel.send_embed do |embed|
        embed_comment(embed, channel.name, comment, users, posts)
      end
    end

    comments.last&.created_at || last_checked_at
  end

  def update_forum_feed(last_checked_at, channel)
    log.debug("Checking /forum_posts (last seen: #{last_checked_at}).")

    forum_posts = booru.forum_posts.newest(last_checked_at, 50).reverse

    creator_ids = forum_posts.map(&:creator_id).join(",")
    users = booru.users.search(id: creator_ids).group_by(&:id).transform_values(&:first)

    topic_ids = forum_posts.map(&:topic_id).join(",")
    forum_topics = booru.forum_topics.search(id: topic_ids).group_by(&:id).transform_values(&:first)

    forum_posts.each do |forum_post|
      channel.send_embed do |embed|
        embed_forum_post(embed, forum_post, forum_topics, users)
      end
    end

    forum_posts.last&.created_at || last_checked_at
  end

  def initiate_shutdown!
    @initiate_shutdown = true
  end
end
