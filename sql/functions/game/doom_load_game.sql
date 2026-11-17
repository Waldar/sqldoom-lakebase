CREATE OR REPLACE FUNCTION doom.doom_load_game(p_slot integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  target integer;
  _r1 record;
BEGIN

-- Returns the restored map_id, or -1 when the slot is empty.
target := -1;
FOR _r1 IN SELECT COALESCE(MIN(map_id),-1) AS m FROM save_slots WHERE slot=doom_load_game.p_slot::int
LOOP target := _r1.m; END LOOP;
IF _cs.target >= 0 THEN
  DELETE FROM player_state WHERE map_id=_cs.target;
  INSERT INTO player_state (map_id,player_thing_id,health,alive,level_tics,previous_x,previous_y,position_x,position_y,base_z,view_z,view_angle,momentum_x,momentum_y,bob_strength,previous_view_z,previous_view_angle,sector_id,pain_face_tics,armor,armor_class,backpack,ammo_bullets,ammo_shells,ammo_rockets,ammo_cells,key_blue,key_yellow,key_red,radsuit_tics,invis_tics,momentum_z,damage_count,bonus_count,light_amp_tics,power_map,god_mode,noclip,invuln_tics,berserk,message,message_tics,frags,death_tics,killer_id,sprite_frame)
  SELECT map_id,player_thing_id,health,alive,level_tics,previous_x,previous_y,position_x,position_y,base_z,view_z,view_angle,momentum_x,momentum_y,bob_strength,previous_view_z,previous_view_angle,sector_id,pain_face_tics,armor,armor_class,backpack,ammo_bullets,ammo_shells,ammo_rockets,ammo_cells,key_blue,key_yellow,key_red,radsuit_tics,invis_tics,momentum_z,damage_count,bonus_count,light_amp_tics,power_map,god_mode,noclip,invuln_tics,berserk,message,message_tics,frags,death_tics,killer_id,sprite_frame FROM save_player_state WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM player_weapons WHERE map_id=_cs.target;
  INSERT INTO player_weapons (map_id,player_thing_id,current_weapon,pending_weapon,state,seq_index,tics,flash_seq_index,flash_tics,sx,sy,shot_serial,fired_this_tick)
  SELECT map_id,player_thing_id,current_weapon,pending_weapon,state,seq_index,tics,flash_seq_index,flash_tics,sx,sy,shot_serial,fired_this_tick FROM save_player_weapons WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM player_weapon_owned WHERE map_id=_cs.target;
  INSERT INTO player_weapon_owned (map_id,player_thing_id,weapon_id)
  SELECT map_id,player_thing_id,weapon_id FROM save_player_weapon_owned WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM things WHERE map_id=_cs.target;
  INSERT INTO things (id,map_id,x,y,z,angle,spawn_x,spawn_y,spawn_angle,mom_x,mom_y,type,flags)
  SELECT id,map_id,x,y,z,angle,spawn_x,spawn_y,spawn_angle,mom_x,mom_y,type,flags FROM save_things WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM thing_health WHERE map_id=_cs.target;
  INSERT INTO thing_health (map_id,thing_id,health,max_health,alive)
  SELECT map_id,thing_id,health,max_health,alive FROM save_thing_health WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM monster_ai WHERE map_id=_cs.target;
  INSERT INTO monster_ai (map_id,thing_id,state,state_tics,seq_index,sector_id,attack_cooldown,fired_this_tick,target_thing_id,charge_tics,movedir,movecount)
  SELECT map_id,thing_id,state,state_tics,seq_index,sector_id,attack_cooldown,fired_this_tick,target_thing_id,charge_tics,movedir,movecount FROM save_monster_ai WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM monster_projectiles WHERE map_id=_cs.target;
  INSERT INTO monster_projectiles (map_id,projectile_id,owner_thing_id,projectile_type,x,y,z,vx,vy,vz,sector_id,state,age,damage,impact_player)
  SELECT map_id,projectile_id,owner_thing_id,projectile_type,x,y,z,vx,vy,vz,sector_id,state,age,damage,impact_player FROM save_monster_projectiles WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM world_effects WHERE map_id=_cs.target;
  INSERT INTO world_effects (map_id,effect_id,effect_type,x,y,z,sector_id,age)
  SELECT map_id,effect_id,effect_type,x,y,z,sector_id,age FROM save_world_effects WHERE slot=doom_load_game.p_slot::int;
  -- The one place this function cannot keep its delete/insert pairs together:
  -- sidedefs reference sectors, so the children go first and come back last.
  DELETE FROM sidedefs WHERE map_id=_cs.target;
  DELETE FROM sectors WHERE map_id=_cs.target;
  INSERT INTO sectors (id,map_id,floor_height,ceil_height,spawn_floor_height,spawn_ceil_height,spawn_floor_tex,spawn_light_level,floor_tex,ceil_tex,light_level,special,tag)
  SELECT id,map_id,floor_height,ceil_height,spawn_floor_height,spawn_ceil_height,spawn_floor_tex,spawn_light_level,floor_tex,ceil_tex,light_level,special,tag FROM save_sectors WHERE slot=doom_load_game.p_slot::int;
  INSERT INTO sidedefs (id,map_id,x_offset,y_offset,upper_tex,lower_tex,mid_tex,sector_id)
  SELECT id,map_id,x_offset,y_offset,upper_tex,lower_tex,mid_tex,sector_id FROM save_sidedefs WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM sector_movers WHERE map_id=_cs.target;
  INSERT INTO sector_movers (map_id,sector_id,source_line_id,mover_type,plane,direction,bottom_height,top_height,speed,move_carry,wait_tics,countdown,next_ceiling,next_floor,target_floor_tex,moved_this_tick,crush)
  SELECT map_id,sector_id,source_line_id,mover_type,plane,direction,bottom_height,top_height,speed,move_carry,wait_tics,countdown,next_ceiling,next_floor,target_floor_tex,moved_this_tick,crush FROM save_sector_movers WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM line_buttons WHERE map_id=_cs.target;
  INSERT INTO line_buttons (map_id,line_id,sidedef_id,texture_part,original_tex,active_tex,countdown,just_restored)
  SELECT map_id,line_id,sidedef_id,texture_part,original_tex,active_tex,countdown,just_restored FROM save_line_buttons WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM line_activations WHERE map_id=_cs.target;
  INSERT INTO line_activations (map_id,line_id)
  SELECT map_id,line_id FROM save_line_activations WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM picked_up_items WHERE map_id=_cs.target;
  INSERT INTO picked_up_items (map_id,thing_id)
  SELECT map_id,thing_id FROM save_picked_up_items WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM level_secret_discoveries WHERE map_id=_cs.target;
  INSERT INTO level_secret_discoveries (map_id,player_thing_id,sector_id)
  SELECT map_id,player_thing_id,sector_id FROM save_level_secret_discoveries WHERE slot=doom_load_game.p_slot::int;
  DELETE FROM level_stats WHERE map_id=_cs.target;
  INSERT INTO level_stats (map_id,player_thing_id,skill_bit,level_tics,par_tics,kills,total_kills,items,total_items,secrets,total_secrets,completed,secret_exit)
  SELECT map_id,player_thing_id,skill_bit,level_tics,par_tics,kills,total_kills,items,total_items,secrets,total_secrets,completed,secret_exit FROM save_level_stats WHERE slot=doom_load_game.p_slot::int;
  -- Nothing half-finished from the old session may survive:
  -- these are rebuilt every tic and a stale row would fire.
  DELETE FROM game_tic_commands WHERE map_id=_cs.target;
  DELETE FROM line_special_events WHERE map_id=_cs.target;
  DELETE FROM line_use_results WHERE map_id=_cs.target;
  DELETE FROM pickup_touches WHERE map_id=_cs.target;
  DELETE FROM pickup_grants WHERE map_id=_cs.target;
  DELETE FROM sound_events WHERE map_id=_cs.target;
  DELETE FROM hitscan_hits WHERE map_id=_cs.target;
  DELETE FROM projectile_damage WHERE map_id=_cs.target;
  DELETE FROM projectile_impacts WHERE map_id=_cs.target;
  DELETE FROM monster_attack_damage WHERE map_id=_cs.target;
  -- Derived mirrors, rebuilt from the state just restored.
  PERFORM doom_materialize_render_segs(_cs.target);
  PERFORM doom_materialize_render_things(_cs.target);
  DELETE FROM sector_light_fx WHERE map_id=_cs.target;
  INSERT INTO sector_light_fx
    (map_id, sector_id, special, base_light, dark_light)
  SELECT s.map_id, s.id, s.special::smallint,
         COALESCE(s.spawn_light_level, s.light_level)::smallint,
         LEAST(COALESCE(s.spawn_light_level, s.light_level),
               COALESCE(MIN(other.light_level), 0::smallint))::smallint
  FROM sectors s
  LEFT JOIN linedefs edge ON edge.map_id = s.map_id
  LEFT JOIN sidedefs r ON r.map_id = edge.map_id AND r.id = edge.right_sd_id
  LEFT JOIN sidedefs l ON l.map_id = edge.map_id AND l.id = edge.left_sd_id
  LEFT JOIN sectors other ON other.map_id = s.map_id
    AND other.id = CASE WHEN r.sector_id = s.id THEN l.sector_id
                        WHEN l.sector_id = s.id THEN r.sector_id END
  WHERE s.map_id = _cs.target AND s.special IN (1,2,3,8,12,13,17)
  GROUP BY s.map_id, s.id, s.special, s.spawn_light_level, s.light_level;
END IF;
RETURN _cs.target;
END _cs;
$function$;
