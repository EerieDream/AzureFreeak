/datum/lift_master/tram

	///whether this tram is traveling across vertical and/or horizontal axis for some distance. not all lifts use this
	var/travelling = FALSE
	///if we're travelling, what direction are we going
	var/travel_direction = NONE
	///if we're travelling, how far do we have to go
	var/travel_distance = 0
	///how far in total we'll be travelling
	var/travel_trip_length = 0

	///multiplier on how much damage/force the tram imparts on things it hits
	var/collision_lethality = 1

	/// reference to the destination landmark we consider ourselves "at". since we potentially span multiple z levels we dont actually
	/// know where on us this platform is. as long as we know THAT its on us we can just move the distance and direction between this
	/// and the destination landmark.
	var/obj/effect/landmark/tram/idle_platform

	///decisecond delay between horizontal movement. cannot make the tram move faster than 1 movement per world.tick_lag.
	///this var is poorly named its actually horizontal movement delay but whatever.
	var/horizontal_speed = 4

	///version of horizontal_speed that gets set in init and is considered our base speed if our lift gets slowed down
	var/base_horizontal_speed = 4

	///the world.time we should next move at. in case our speed is set to less than 1 movement per tick
	var/next_move = INFINITY

	///whether we have been slowed down automatically
	var/slowed_down = FALSE

	///how many times we moved while costing more than SStramprocess.max_time milliseconds per movement.
	///if this exceeds SStramprocess.max_exceeding_moves
	var/times_exceeded = 0

	///how many times we moved while costing less than 0.5 * SStramprocess.max_time milliseconds per movement
	var/times_below = 0

	var/is_operational = TRUE

	var/obj/effect/landmark/tram/callback_platform

/datum/lift_master/tram/New(obj/structure/industrial_lift/tram/lift_platform)
	. = ..()
	horizontal_speed = lift_platform.horizontal_speed
	base_horizontal_speed = lift_platform.horizontal_speed

	check_starting_landmark()

/datum/lift_master/tram/vv_edit_var(var_name, var_value)
	. = ..()
	if(var_name == "base_horizontal_speed")
		horizontal_speed = max(horizontal_speed, base_horizontal_speed)

/datum/lift_master/tram/add_lift_platforms(obj/structure/industrial_lift/new_lift_platform)
	. = ..()
	RegisterSignal(new_lift_platform, COMSIG_MOVABLE_BUMP, PROC_REF(gracefully_break))

/datum/lift_master/tram/check_for_landmarks(obj/structure/industrial_lift/tram/new_lift_platform)
	. = ..()
	for(var/turf/platform_loc as anything in new_lift_platform.locs)
		var/obj/effect/landmark/tram/initial_destination = locate() in platform_loc

		if(initial_destination)
			idle_platform = initial_destination

/datum/lift_master/tram/proc/check_starting_landmark()
	if(!idle_platform)
		CRASH("a tram lift_master was initialized without any tram landmark to give it direction!")

	SStramprocess.can_fire = TRUE

	return TRUE

/**
 * Signal for when the tram runs into a field of which it cannot go through.
 * Stops the train's travel fully, sends a message, and destroys the train.
 * Arguments:
 * bumped_atom - The atom this tram bumped into
 */
/datum/lift_master/tram/proc/gracefully_break(atom/bumped_atom)
	SIGNAL_HANDLER

	travel_distance = 0
	bumped_atom.visible_message(span_userdanger("The [bumped_atom.name] crashes into the field violently!"))
	for(var/obj/structure/industrial_lift/tram/tram_part as anything in lift_platforms)
		tram_part.set_travelling(FALSE)
		for(var/tram_contents in tram_part.lift_load)
			if(iseffect(tram_contents))
				continue

			if(isliving(tram_contents))
				explosion(tram_contents, devastation_range = rand(0, 1), heavy_impact_range = 2, light_impact_range = 3) //50% chance of gib

			else if(prob(9))
				explosion(tram_contents, devastation_range = 1, heavy_impact_range = 2, light_impact_range = 3)

			explosion(tram_part, devastation_range = 1, heavy_impact_range = 2, light_impact_range = 3)
			qdel(tram_part)

/**
 * Handles moving the tram
 *
 * Tells the individual tram parts where to actually go and has an extra safety checks
 * incase multiple inputs get through, preventing conflicting directions and the tram
 * literally ripping itself apart. all of the actual movement is handled by SStramprocess
 * Arguments: destination platform, rapid (bypass some safety checks)
 */
/datum/lift_master/tram/proc/tram_travel(obj/effect/landmark/tram/destination_platform, rapid = TRUE)
	if(destination_platform == idle_platform)
		return

	travel_direction = get_dir(idle_platform, destination_platform)
	travel_distance = get_dist(idle_platform, destination_platform)
	travel_trip_length = travel_distance
	idle_platform = destination_platform
	callback_platform = destination_platform
	set_travelling(TRUE)
	set_controls(LIFT_PLATFORM_LOCKED)
	if(rapid) // bypass for unsafe, rapid departure
		dispatch_tram(destination_platform)
	else
		addtimer(CALLBACK(src, PROC_REF(dispatch_tram), destination_platform), 3 SECONDS)

/datum/lift_master/tram/proc/dispatch_tram(obj/effect/landmark/tram/destination_platform)
	SEND_SIGNAL(src, COMSIG_TRAM_TRAVEL, idle_platform, destination_platform)

	for(var/obj/structure/industrial_lift/tram/tram_part as anything in lift_platforms) //only thing everyone needs to know is the new location.
		if(tram_part.travelling) //wee woo wee woo there was a double action queued. damn multi tile structs
			return //we don't care to undo locked controls, though, as that will resolve itself

		tram_part.glide_size_override = DELAY_TO_GLIDE_SIZE(horizontal_speed)
		tram_part.set_travelling(TRUE)

	next_move = world.time + horizontal_speed

	START_PROCESSING(SStramprocess, src)

/datum/lift_master/tram/process(seconds_per_tick)
	if(!travel_distance)
		addtimer(CALLBACK(src, PROC_REF(unlock_controls), idle_platform), 2 SECONDS)
		if(SEND_SIGNAL(callback_platform, COMSIG_TRAM_REACHED_PLATFORM, src))
			return
		return PROCESS_KILL
	else if(world.time >= next_move)
		var/start_time = TICK_USAGE
		travel_distance--

		move_lift_horizontally(travel_direction)

		var/duration = TICK_USAGE_TO_MS(start_time)
		if(slowed_down)
			if(duration <= (SStramprocess.max_time / 2))
				times_below++
			else
				times_below = 0

			if(times_below >= SStramprocess.max_cheap_moves)
				horizontal_speed = base_horizontal_speed
				slowed_down = FALSE
				times_below = 0

		else if(duration > SStramprocess.max_time)
			times_exceeded++

			if(times_exceeded >= SStramprocess.max_exceeding_moves)
				message_admins("The tram at [ADMIN_JMP(lift_platforms[1])] is taking more than [SStramprocess.max_time] milliseconds per movement, halving its movement speed. if this continues to be a problem you can call reset_lift_contents() on the trams lift_master_datum to reset it to its original state and clear added objects")
				horizontal_speed = base_horizontal_speed * 2 //halves its speed
				slowed_down = TRUE
				times_exceeded = 0
		else
			times_exceeded = max(times_exceeded - 1, 0)

		next_move = world.time + horizontal_speed

/**
 * Handles unlocking the tram controls for use after moving
 *
 * More safety checks to make sure the tram has actually docked properly
 * at a location before users are allowed to interact with the tram console again.
 * Tram finds its location at this point before fully unlocking controls to the user.
 */
/datum/lift_master/tram/proc/unlock_controls(obj/effect/landmark/tram/tram_mark)
	if(idle_platform != tram_mark)
		return
	set_travelling(FALSE)
	set_controls(LIFT_PLATFORM_UNLOCKED)
	for(var/obj/structure/industrial_lift/tram/tram_part as anything in lift_platforms) //only thing everyone needs to know is the new location.
		tram_part.set_travelling(FALSE)


/datum/lift_master/tram/proc/set_travelling(new_travelling)
	if(travelling == new_travelling)
		return

	travelling = new_travelling
	SEND_SIGNAL(src, COMSIG_TRAM_SET_TRAVELLING, travelling)
