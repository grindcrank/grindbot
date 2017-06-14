require 'twitter_ebooks'

# This is an example bot definition with event handlers commented out
# You can define and instantiate as many bots as you like
DELAY = 2..30 # Simulated human reply delay range, in seconds
BLACKLIST = [] # users to avoid interaction with
SPECIAL_WORDS = ['bot', 'bots', 'guten', 'morgen', 'wurstbrot'] # Words we like
BANNED_WORDS = [] # Words we don't want to use
ROBOT_ID = 'bot'
# liest weitere Stoppworte aus eine Datei
STOPWORDS = IO.readlines('model/stopwords.txt').map(&:strip)
# STOPWORDS = []
puts "Stopwords: #{STOPWORDS.join(', ')}"

class MyBot < Ebooks::Bot
  # Configuration here applies to all MyBots
  def configure
    # Consumer details come from registering an app at https://dev.twitter.com/
    # Once you have consumer details, use "ebooks auth" for new access tokens
    self.consumer_key = 'HIER_CONSUMER_KEY_EINSETZEN' # Your app consumer key
    self.consumer_secret = 'HIER_CONSUMER_SECRET_EINSETZEN' # Your app consumer secret

    # Users to block instead of interacting with
    self.blacklist = []

    # Range in seconds to randomize delay when bot.delay is called
    self.delay_range = 1..6
  end

  def on_startup
    $have_talked={}
    # See https://github.com/jmettraux/rufus-scheduler
    # Stoppwörter rauswerfen
    @model = Ebooks::Model.load('model/grindcrank.model')
    keywords = @model.keywords.find_all { |t| !STOPWORDS.include?(t.to_s.downcase) }
    keywords = keywords[0..100].map(&:to_s).map(&:downcase)
    @top100 = keywords
    @top50 = keywords[0..50]
    puts "Top 100 interesting: #{@top100.join(', ')}"
    # Reset list of mention recipients every 12 hrs:
    scheduler.every '12h' do
      $have_talked = {}
    end

    # 50% chance to tweet every 63 minutes
    scheduler.every '63m' do
      if rand <= 0.5
        tweet @model.make_statement
      end
    end
  end

  def on_message(dm)
    # Reply to a DM
    # Boss-Kontrollmodus
    if dm.sender.screen_name == 'grindcrank'
      reply_boss dm
    # Unfollow-Wünsche
    elsif dm.text.downcase.strip == 'unfollow me'
        log "Unfollowing @#{dm.sender.screen_name} on request"
        twitter.unfollow dm.sender.screen_name
    else
      delay DELAY do
        reply dm, @model.make_response(dm.text)
      end
    end
  end

  def on_follow(user)
    # Follow a user back
    # follow(user.screen_name)
    # delay DELAY do
    #  follow user.screen_name
    # end
  end

  def on_mention(tweet)
    # Reply to a mention
    # reply(tweet, "oh hullo")
    log 'Someone mentioned me!'
    # Avoid infinite reply chains
    return if tweet.user.screen_name.include?(ROBOT_ID) && rand > 0.05

    author = tweet.user.screen_name
    # Wenn wir schon >= 5 Mal mit dem Autor interagiert haben, ist erstmal Ruhe
    return if $have_talked.fetch(author, 0) >= 5
    $have_talked[author] = $have_talked.fetch(author, 0) + 1

    tokens = Ebooks::NLP.tokenize(tweet.text)
    very_interesting = tokens.find_all { |t| @top50.include?(t.downcase) }.length > 1
    special = tokens.find { |t| SPECIAL_WORDS.include?(t) }

    if very_interesting || special
      favorite(tweet)
    end

    reply_meta(tweet, meta(tweet))
    # Ab und zu etwas Liebe verbreiten
    reply_love(tweet, meta(tweet)) if rand < 0.05
    # follow(author) if rand < 0.2
  end

  def on_timeline(tweet)
    # Reply to a tweet in the bot's timeline
    log 'Something happened in the timeline!'
    log "#{tweet.user.screen_name} wrote:\n#{tweet.text}"

    # Keine Retweets retweeten
    return if tweet.retweeted? || tweet.text.start_with?('RT')
    # Autor in Blacklist?
    author = tweet.user.screen_name
    return if BLACKLIST.include?(author)

    # Tweet enthält Links
    if tweet.uris?
      log "Detected Linkspam"
      return
    end

    # Tweet auseinanderbauen
    tokens = Ebooks::NLP.tokenize(tweet.text)

    # We calculate unprompted interaction probability by how well a
    # tweet matches our keywords
    # Interessant: Ein getwittertes Wort ist in meiner Top-100-Liste
    interesting = tokens.find { |t| @top100.include?(t.downcase) }
    # Sehr interessant: Mindestens zwei Wörter des Tweets sind in meiner Top-50-Liste
    very_interesting = tokens.find_all { |t| @top50.include?(t.downcase) }.length > 1
    special = tokens.find { |t| SPECIAL_WORDS.include?(t) }

    # Tweets mit "speziellen" Wörtern immer faven, dem Autor folgen
    if special
      favorite(tweet)
      favd = true # Mark this tweet as favorited

      delay DELAY do
        follow author
      end
    end

    # Any given user will receive at most one random interaction per 12h
    # (barring special cases)
    return if $have_talked[author]
    $have_talked[author] = $have_talked.fetch(author, 0) + 1

    if very_interesting || special
      favorite(tweet) if (rand < 0.5 && !favd) # Don't fav the tweet if we did earlier
      retweet(tweet) if rand < 0.2
      reply_meta(tweet, meta(tweet)) if rand < 0.1
    elsif interesting
      favorite(tweet) if rand < 0.1
      retweet(tweet) if rand < 0.2
      reply_meta(tweet, meta(tweet)) if rand < 0.05
    else
      retweet(tweet) if rand < 0.1
      reply_meta(tweet, meta(tweet)) if rand < 0.05
    end
  end

  def on_favorite(user, tweet)
    # Follow user who just favorited bot's tweet
    follow(user.screen_name) if rand < 0.1
  end

  def reply_meta(tweet, meta)
    # Check, ob mir der User noch folgt
    if !twitter.friendship?(tweet.user.screen_name, username)
      log "@#{tweet.user.screen_name} is not following me"
      # Wenn nein, dann mit 20% Wahrscheinlichkeit entfolgen
      if rand < 0.2
        log "Unfollowing @#{tweet.user.screen_name}"
        twitter.unfollow tweet.user.screen_name
      end
    end
    # Zuviele Mentions? => kein reply
    unless check_mentions tweet
      log "Too many mentions, no reply"
      return
    end
    log "Replying to @#{tweet.user.screen_name}, who wrote #{tweet.text}"
    resp = @model.make_response(meta.mentionless, meta.limit)
    delay DELAY do
      reply tweet, meta.reply_prefix + resp
    end
  end

  # Liebe verbreiten  
  def reply_love(tweet, meta)
    log "Replying to @#{tweet.user.screen_name} with love"
    delay DELAY do
      reply tweet, "<3"
    end
  end  

  def favorite(tweet)
    log "Favoriting @#{tweet.user.screen_name}: #{tweet.text}"
    delay DELAY do
      twitter.favorite(tweet.id)
    end
  end

  def retweet(tweet)
  #  log "Retweeting @#{tweet.user.screen_name}: #{tweet.text}"
  #  delay DELAY do
  #    twitter.retweet(tweet.id)
  #  end
  end

  def check_mentions tweet
    return tweet.user_mentions.size <= 3
  end

  # Boss-Kontrollmodus
  def reply_boss dm
    if dm.text.downcase =~ /unfollow .*/
      dm.user_mentions.each do |to_unfollow|
        name = to_unfollow.screen_name
        delay DELAY do
          log "Unfollowing @#{name} on command"
          reply dm, "Okay boss, I am unfollowing @#{name}"
          twitter.unfollow name
        end
      end
      return
    end
    if dm.text.downcase =~ /block .*/
      dm.user_mentions.each do |to_unfollow|
        name = to_unfollow.screen_name
        delay DELAY do
          log "Blocking @#{name} on command"
          reply dm, "Okay boss, I am blocking @#{name}"
          twitter.block name
        end
      end
      return
    end
    # normale Unterhaltung via DM
    delay DELAY do
      reply dm, @model.make_response(dm.text)
    end
  end

end

# Make a MyBot and attach it to an account
MyBot.new('grindbot') do |bot|
  bot.access_token = 'HIER_ACCESS_TOKEN_EINSETZEN' # Token connecting the app to this account
  bot.access_token_secret = 'HIER_ACCESS_TOKEN_SECRET_EINSETZEN' # Secret connecting the app to this account
end
