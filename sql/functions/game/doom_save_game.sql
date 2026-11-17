CREATE OR REPLACE FUNCTION doom.doom_save_game(p_slot integer, p_map_id integer, p_player_thing_id integer, p_skill integer, p_name text)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

DELETE FROM save_slots WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_slots (slot,saved_at,name,map_id,player_thing_id,map_name,skill)
SELECT doom_save_game.p_slot::int, NOW(), doom_save_game.p_name::text, doom_save_game.p_map_id::int,
       doom_save_game.p_player_thing_id::int,
       (SELECT m.name FROM maps m WHERE m.map_id=doom_save_game.p_map_id::int),
       -- The skill the WORLD was built with, taken from
       -- level_stats rather than the caller. reset_stage seeds
       -- thing_health/monster_ai per skill, so a save that
       -- recorded a different skill than its own world loaded
       -- with monsters that had no health and no AI row: they
       -- rendered alive, never attacked, and cost frame time.
       COALESCE((SELECT ls.skill_bit FROM level_stats ls
                  WHERE ls.map_id=doom_save_game.p_map_id::int
                    AND ls.player_thing_id=doom_save_game.p_player_thing_id::int),
                doom_save_game.p_skill::int);

DELETE FROM save_player_state WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_player_state (slot,map_id,player_thing_id,health,alive,level_tics,previous_x,previous_y,position_x,position_y,base_z,view_z,view_angle,momentum_x,momentum_y,bob_strength,previous_view_z,previous_view_angle,sector_id,pain_face_tics,armor,armor_class,backpack,ammo_bullets,ammo_shells,ammo_rockets,ammo_cells,key_blue,key_yellow,key_red,radsuit_tics,invis_tics,momentum_z,damage_count,bonus_count,light_amp_tics,power_map,god_mode,noclip,invuln_tics,berserk,message,message_tics,frags,death_tics,killer_id,sprite_frame)
SELECT doom_save_game.p_slot::int,map_id,player_thing_id,health,alive,level_tics,previous_x,previous_y,position_x,position_y,base_z,view_z,view_angle,momentum_x,momentum_y,bob_strength,previous_view_z,previous_view_angle,sector_id,pain_face_tics,armor,armor_class,backpack,ammo_bullets,ammo_shells,ammo_rockets,ammo_cells,key_blue,key_yellow,key_red,radsuit_tics,invis_tics,momentum_z,damage_count,bonus_count,light_amp_tics,power_map,god_mode,noclip,invuln_tics,berserk,message,message_tics,frags,death_tics,killer_id,sprite_frame FROM player_state WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_player_weapons WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_player_weapons (slot,map_id,player_thing_id,current_weapon,pending_weapon,state,seq_index,tics,flash_seq_index,flash_tics,sx,sy,shot_serial,fired_this_tick)
SELECT doom_save_game.p_slot::int,map_id,player_thing_id,current_weapon,pending_weapon,state,seq_index,tics,flash_seq_index,flash_tics,sx,sy,shot_serial,fired_this_tick FROM player_weapons WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_player_weapon_owned WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_player_weapon_owned (slot,map_id,player_thing_id,weapon_id)
SELECT doom_save_game.p_slot::int,map_id,player_thing_id,weapon_id FROM player_weapon_owned WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_things WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_things (slot,id,map_id,x,y,z,angle,spawn_x,spawn_y,spawn_angle,mom_x,mom_y,type,flags)
SELECT doom_save_game.p_slot::int,id,map_id,x,y,z,angle,spawn_x,spawn_y,spawn_angle,mom_x,mom_y,type,flags FROM things WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_thing_health WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_thing_health (slot,map_id,thing_id,health,max_health,alive)
SELECT doom_save_game.p_slot::int,map_id,thing_id,health,max_health,alive FROM thing_health WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_monster_ai WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_monster_ai (slot,map_id,thing_id,state,state_tics,seq_index,sector_id,attack_cooldown,fired_this_tick,target_thing_id,charge_tics,movedir,movecount)
SELECT doom_save_game.p_slot::int,map_id,thing_id,state,state_tics,seq_index,sector_id,attack_cooldown,fired_this_tick,target_thing_id,charge_tics,movedir,movecount FROM monster_ai WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_monster_projectiles WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_monster_projectiles (slot,map_id,projectile_id,owner_thing_id,projectile_type,x,y,z,vx,vy,vz,sector_id,state,age,damage,impact_player)
SELECT doom_save_game.p_slot::int,map_id,projectile_id,owner_thing_id,projectile_type,x,y,z,vx,vy,vz,sector_id,state,age,damage,impact_player FROM monster_projectiles WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_world_effects WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_world_effects (slot,map_id,effect_id,effect_type,x,y,z,sector_id,age)
SELECT doom_save_game.p_slot::int,map_id,effect_id,effect_type,x,y,z,sector_id,age FROM world_effects WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_sectors WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_sectors (slot,id,map_id,floor_height,ceil_height,spawn_floor_height,spawn_ceil_height,spawn_floor_tex,spawn_light_level,floor_tex,ceil_tex,light_level,special,tag)
SELECT doom_save_game.p_slot::int,id,map_id,floor_height,ceil_height,spawn_floor_height,spawn_ceil_height,spawn_floor_tex,spawn_light_level,floor_tex,ceil_tex,light_level,special,tag FROM sectors WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_sidedefs WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_sidedefs (slot,id,map_id,x_offset,y_offset,upper_tex,lower_tex,mid_tex,sector_id)
SELECT doom_save_game.p_slot::int,id,map_id,x_offset,y_offset,upper_tex,lower_tex,mid_tex,sector_id FROM sidedefs WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_sector_movers WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_sector_movers (slot,map_id,sector_id,source_line_id,mover_type,plane,direction,bottom_height,top_height,speed,move_carry,wait_tics,countdown,next_ceiling,next_floor,target_floor_tex,moved_this_tick,crush)
SELECT doom_save_game.p_slot::int,map_id,sector_id,source_line_id,mover_type,plane,direction,bottom_height,top_height,speed,move_carry,wait_tics,countdown,next_ceiling,next_floor,target_floor_tex,moved_this_tick,crush FROM sector_movers WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_line_buttons WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_line_buttons (slot,map_id,line_id,sidedef_id,texture_part,original_tex,active_tex,countdown,just_restored)
SELECT doom_save_game.p_slot::int,map_id,line_id,sidedef_id,texture_part,original_tex,active_tex,countdown,just_restored FROM line_buttons WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_line_activations WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_line_activations (slot,map_id,line_id)
SELECT doom_save_game.p_slot::int,map_id,line_id FROM line_activations WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_picked_up_items WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_picked_up_items (slot,map_id,thing_id)
SELECT doom_save_game.p_slot::int,map_id,thing_id FROM picked_up_items WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_level_secret_discoveries WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_level_secret_discoveries (slot,map_id,player_thing_id,sector_id)
SELECT doom_save_game.p_slot::int,map_id,player_thing_id,sector_id FROM level_secret_discoveries WHERE map_id=doom_save_game.p_map_id::int;

DELETE FROM save_level_stats WHERE slot=doom_save_game.p_slot::int;
INSERT INTO save_level_stats (slot,map_id,player_thing_id,skill_bit,level_tics,par_tics,kills,total_kills,items,total_items,secrets,total_secrets,completed,secret_exit)
SELECT doom_save_game.p_slot::int,map_id,player_thing_id,skill_bit,level_tics,par_tics,kills,total_kills,items,total_items,secrets,total_secrets,completed,secret_exit FROM level_stats WHERE map_id=doom_save_game.p_map_id::int;

RETURN doom_save_game.p_slot::int;
END _cs;
$function$;
