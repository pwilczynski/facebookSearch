class GameController < ApplicationController

  def splash
    #run animation on splash page
    @animatePhotosFlag = true
  end

  def answer
    # post an answer via AJAX
    # params :fb_id, :name => guess, :success

    #get user data	
    result = @fb_graph.fql_query("SELECT uid,name,sex,birthday_date,affiliations FROM user WHERE uid = " + params[:fb_id].to_s)   		

    #fail if bad user
    if !result[0]["uid"]
      render :json => {}, :status => :bad_request
      return
    end

    if(params[:name] == "unfair")
      #TODO: What do we want to do about it? Ignore maybe? Log it somewhere?
      render :json => {}, :status => :ok
      return
    end

    # save attempt to DB 
    @current_user.attempts.create({ :target_facebook_id => result[0]["uid"],
      :correct => params[:success],
      :guessed_name => params[:name], 
      :actual_name => result[0]["name"],
      :affiliations => ActiveSupport::JSON.encode(result[0]["affiliations"].map{|a| a["nid"].to_i}),
      :gender => result[0]["sex"], 
      :age => User.age_from_bday_string( result[0]["birthday_date"] )
      })
      #return success
      render :json => {}, :status => :ok
    end



    def grab_friends

      #set defaults (if necessary) and convert to ints
      params[:limit] = params[:limit].to_i || 10
      params[:limit] = 10 if(params[:limit] > 15)
      params[:avoid] = params[:avoid].map{|v| v.to_i} rescue [] 
      puts "--AJAX call for  " + params[:limit].to_s + " friends."
      
      #grab friends from facebook
      s = Time.now
      friends = @fb_graph.fql_query("SELECT uid,name FROM user WHERE uid IN (SELECT uid2 FROM friend WHERE uid1 = me())")
      puts "--Grab friends: " + (Time.now - s).to_s
      
      
      #Remove any repeats, and sample
      s = Time.now
      friends_in_db = @current_user.attempts.collect{|a| a.target_facebook_id}
      friends.reject! {|f| params[:avoid].include?(f["uid"].to_i) || friends_in_db.include?(f["uid"].to_i)}
      friends = friends.sample( params[:limit] )
      
      if (friends.length == 0)
        puts "No friends left!"
        return nil
      end
      puts "--Select friends: " + (Time.now - s).to_s
      
      
      #Batch API to grab photos
      s = Time.now
      results = @fb_graph.batch do |batch_api|
        friends.each do |f|
          batch_api.get_connections(f['uid'], "photos?limit=15")	#Grab 15, end up with 3 so we get some randomness not just newest 3
        end
      end
      puts "--Batch grab photos: " + (Time.now - s).to_s


      #Finally attach them to the friends object to be sent back
      s = Time.now
      results.each_with_index do |r_arr,idx|
        photos = r_arr.map do |r|
          tag = r["tags"]["data"].detect{|t| t["id"].to_i == friends[idx]["uid"].to_i}
          {:xcoord => tag["x"],:ycoord => tag["y"],:src => r["source"],:total_tags => r["tags"]["data"].length}
        end
        friends[idx]["photos"] = photos.sort_by{|p| p[:total_tags]}.first(8).sample(4)
      end
      puts "--Sort Photos: " + (Time.now - s).to_s


      #format friend objects for javascript, and render response
      friends = friends.map{|f| 
        {
          :fb_id => f['uid'],
          :name => f['name'],
          :big_path => "http://graph.facebook.com/" + f['uid'].to_s + "/picture?type=large",
          :photos => f['photos']
        }
      }
      render :json => friends
      
      
      #Update play count if needed
      if (params[:new_round] == "true" )
        @current_user.play_count += 1
        @current_user.save!
      end

    end

    def results
      #render a full page container in layout
      @fullPageFlag = true

      #calculate aggregate stats
      @overall_correct_pct = Attempt.connection.select_value("
      	SELECT AVG(`correct`) 
      	FROM 
      	(SELECT `user_id`, AVG(`correct`) as `correct`, COUNT(*) as `count`
		        FROM `attempts` a
		        WHERE `guessed_name` != 'unfair'
		        GROUP BY `user_id`
		    ) `s`
      ")

      #break it down by age and genders
      @gender_age_breakdown = Attempt.connection.select_all("
	      SELECT AVG(`correct`) as `pct`,COUNT(*) as `count`,SUM(`count`) as `attempts`, s.`gender`,s.`age` 
			FROM 
			    (SELECT `user_id`, AVG(`correct`) as `correct`, COUNT(*) as `count`,u.`gender`,u.`age` 
			        FROM `attempts` a INNER JOIN `users` u ON `u`.`id` = `a`.`user_id` 
			        WHERE `guessed_name` != 'unfair'
			        GROUP BY `user_id`
			    ) `s` 
			GROUP BY `s`.`age`,`s`.`gender` 
			ORDER BY `age` ASC")
		
      @gender_gender_breakdown = Attempt.connection.select_all("
	      SELECT `user_gender`, s.`gender` as `gender`, AVG(`correct`) as `pct`, SUM(`count`) as `count` 
	      FROM 
			    (SELECT `user_id`, AVG(`correct`) as `correct`, COUNT(*) as `count`, u.`gender` as `user_gender`, a.`gender`, u.`age` 
			        FROM `attempts` a INNER JOIN `users` u ON `u`.`id` = `a`.`user_id` 
			        WHERE `guessed_name` != 'unfair'
			        GROUP BY `user_id`, a.`gender`
			    ) `s`
	      GROUP BY `user_gender`, `gender` 
	      ORDER BY `user_gender` DESC, s.`gender` DESC")
      
      #return here if not signed in 
      @indivFlag = ( @current_user && !@current_user.attempts.blank? )
      return if !@indivFlag


      #Expect a ts if coming from a game, otherwise use all
      if(params[:ts])
        time = Time.at(params[:ts].to_i / 1000) #comes in in milliseconds, to seconds
        time_range = (time - 95.seconds)..Time.now
        @curr_attempts = @current_user.attempts.where(:created_at => time_range)
      else
        @curr_attempts = @current_user.attempts
      end
      @correct_attempts = @curr_attempts.select{|a| a.correct}
      @incorrect_attempts = @curr_attempts.select{|a| !a.correct}		
      @attempts = @current_user.attempts.where("`guessed_name` != 'unfair'") #aggregate 

      # add friend count if missing
      begin
	      if @current_user.friend_count.nil? || @current_user.friend_count < 10 
	        @current_user.friend_count =  @fb_graph.fql_query("SELECT friend_count FROM user WHERE uid = me()")[0]["friend_count"]
	        @current_user.save!
	      else
	      	#Update the friend change so we can track...DO NOT UPDATE THE ORIGINAL NUMBERS!
	      	@current_user.friend_change = @fb_graph.fql_query("SELECT friend_count FROM user WHERE uid = me()")[0]["friend_count"].to_i - @current_user.friend_count
	      	@current_user.save!      
	      end
	  rescue
	  	
	  end

      #computer user scores
      @my_score = @correct_attempts.length.to_f / (@correct_attempts.length + @incorrect_attempts.length) rescue 0
      @my_score = @my_score.nan? ? 1 : @my_score #above rescue is NOT catching, very odd error.
      
      @my_agg_score = @attempts.select{|a| a.correct}.length.to_f / (@attempts.length)
      @fof_count =  (@current_user.friend_count * 880 * 0.5).round

      #grab affiliations
      begin
	      @my_affiliations = @fb_graph.fql_query("SELECT affiliations FROM user WHERE uid = me()").first["affiliations"]
	      @my_affiliations.map!{ |affil|
	        affil_attempts = @attempts.select{ |att| att.affils.include?( affil["nid"].to_i ) }
	        affil_correct = affil_attempts.select{|att| att.correct}
	        affil_accuracy = (affil_correct.length.to_f / affil_attempts.length ) rescue 0
	        {
	          :name => affil['name'],
	          :attempts => affil_attempts.length.to_s,
	          :correct => affil_correct.length.to_s,
	          :accuracy => affil_accuracy.to_s
	        }
	      }
	  rescue
	  
	  end




    end
  end
