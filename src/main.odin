package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

COMMAND_BUF_SIZE :: 256

command_buf: [COMMAND_BUF_SIZE]u8
input_focused: bool

// Temporary
handle_command :: proc(cmd: string)
{
	if len(cmd) == 0
	{return}

	if cmd[0] != '/'
	{
		fmt.printf("[Chat] %s\n", cmd)
		return
	}

	if strings.has_prefix(cmd, "/join ")
	{
		name := cmd[6:]
		if len(name) > 0 && name[0] == '#'
		{name = name[1:]}
		add_channel(name, false)
	}
	 else if cmd == "/leave"
	{
		if g_selected_idx >= 0 && g_selected_idx < g_channel_count
		{
			fmt.printf("Leaving %s\n", g_channels[g_selected_idx].name)
			disconnect_channel(g_selected_idx)
		}
	}
	 else if cmd == "/help"
	{
		fmt.println("Commands:")
		fmt.println("  /join <channel>")
		fmt.println("  /leave")
	}
	 else
	{
		fmt.printf("Unknown command: %s\n", cmd)
	}
}


g_Config: Config
g_loader_thread: ^thread.Thread
g_loader_done: bool

load_channels_proc :: proc(t: ^thread.Thread)
{
	if config_load("config.txt", &g_Config)
	{
		config_print(&g_Config)
		for i in 0 ..< g_Config.channel_count
		{
			ch := &g_Config.channels[i]
			add_channel(ch.name, ch.tts)
		}
	}
	 else
	{
		fmt.println("No config found, starting with defaults")
		add_channel("forsen", true)
	}
	g_loader_done = true
}

main :: proc()
{
	rl.InitWindow(600, 700, strings.clone_to_cstring("Twitch Multi-Chat", context.temp_allocator))
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitAudioDevice()

	font_path := strings.clone_to_cstring("fonts/Cascadia.ttf", context.temp_allocator)
	g_font = rl.LoadFontEx(font_path, FONT_SIZE, nil, 0)
	g_font_loaded = true

	rl.SetTargetFPS(30)

	tts_generate()

	g_loader_thread = thread.create(load_channels_proc)
	thread.start(g_loader_thread)

	start_status_poller()

	for !rl.WindowShouldClose()
	{
		// --- Input ---
		if rl.IsMouseButtonPressed(.LEFT)
		{input_focused = rl.GetMousePosition().y > (f32(rl.GetScreenHeight()) - 60.0)}

		// Enter handling: gather command string from buffer
		if input_focused && rl.IsKeyPressed(.ENTER)
		{
			cmd := string(cstring(&command_buf[0]))
			if len(cmd) > 0
			{
				handle_command(cmd)
				command_buf[0] = 0
			}
		}

		// --- Layout / Draw ---
		rl.BeginDrawing()
		rl.ClearBackground({15, 15, 15, 255})

		pad := f32(10.0)
		header_h := f32(50.0)
		input_h := f32(30.0)
		sidebar_w := f32(50.0) if g_sidebar_minimized else f32(200.0)
		body_h := f32(rl.GetScreenHeight()) - header_h - input_h - (pad * 3)
		chat_w := f32(rl.GetScreenWidth()) - sidebar_w - (pad * 3)

		chat_rect := rl.Rectangle{pad, header_h + pad, chat_w, body_h}
		side_rect := rl.Rectangle{chat_w + (pad * 2), header_h + pad, sidebar_w, body_h}
		input_rect := rl.Rectangle{pad, header_h + body_h + (pad * 2), chat_w, input_h}

		// Chat panel
		if g_selected_idx >= 0 && g_selected_idx < g_channel_count
		{
			sel := &g_channels[g_selected_idx]
			display_buffer: [MAX_MSGS_PER_CHANNEL]DisplayMessage
			count := get_messages_for_display(sel, display_buffer[:])
			draw_chat(chat_rect, display_buffer[0:count], &sel.scroll_offset, &sel.auto_scroll)
		}

		// Sidebar
		if g_sidebar_minimized
		{
			if draw_minimized_channel_list(side_rect)
			{g_sidebar_minimized = false}
		}
		 else
		{
			if g_selected_idx >= 0
			{g_channels[g_selected_idx].was_highlighted = false}

			names: [MAX_CHANNELS]string
			live_status: [MAX_CHANNELS]bool
			live_known: [MAX_CHANNELS]bool
			has_highlight: [MAX_CHANNELS]bool
			sync.mutex_lock(&g_channels_mu)
			for i in 0 ..< g_channel_count
			{
				names[i] = g_channels[i].name
				live_status[i] = g_channels[i].is_live
				live_known[i] = g_channels[i].live_status_known
				has_highlight[i] = g_channels[i].was_highlighted
			}

			sync.mutex_unlock(&g_channels_mu)
			toggle_min := false
			clicked := draw_channel_list(
				side_rect,
				names[0:g_channel_count],
				live_status[0:g_channel_count],
				live_known[0:g_channel_count],
				has_highlight[0:g_channel_count],
				g_selected_idx,
				&toggle_min,
			)
			if toggle_min
			{g_sidebar_minimized = true}

			if clicked != -1 && clicked != g_selected_idx
			{
				g_selected_idx = clicked
				g_channels[g_selected_idx].was_highlighted = false
				fmt.printf("Switched to: %s\n", g_channels[g_selected_idx].name)
			}
			if g_selected_idx >= 0
			{g_channels[g_selected_idx].was_highlighted = false}
		}

		draw_input_box(input_rect, &command_buf, input_focused)

		// Header
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), i32(header_h), {25, 25, 25, 255})
		header_text_c: cstring
		viewer_info_c: cstring
		header_text := "TWITCH MULTI-CHAT"
		viewer_info := ""
		if g_selected_idx >= 0 && g_selected_idx < g_channel_count
		{
			sel := &g_channels[g_selected_idx]
			if !sel.live_status_known
			{header_text = fmt.tprintf(
					"TWITCH MULTI-CHAT  #%s  (%d msgs)  checking...",
					sel.name,
					sel.message_count,
				)}
			 else if !sel.is_live
			{header_text = fmt.tprintf(
					"TWITCH MULTI-CHAT  #%s  (%d msgs)  offline",
					sel.name,
					sel.message_count,
				)}
			 else
			{header_text = fmt.tprintf(
					"TWITCH MULTI-CHAT  #%s  (%d msgs)  LIVE",
					sel.name,
					sel.message_count,
				)
				viewer_info = fmt.tprintf("%d", sel.viewer_count)}
		}
		header_text_c = strings.clone_to_cstring(header_text, context.temp_allocator)
		viewer_info_c = strings.clone_to_cstring(viewer_info, context.temp_allocator)
		rl.DrawTextEx(font(), header_text_c, {20, 15}, FONT_SIZE, 1, rl.RAYWHITE)
		rl.DrawTextEx(
			font(),
			viewer_info_c,
			{20 + rl.MeasureTextEx(font(), header_text_c, FONT_SIZE, 1).x + 45, 15},
			FONT_SIZE,
			1,
			rl.RED,
		)
		rl.DrawTextEx(
			font(),
			strings.clone_to_cstring(" Viewers", context.temp_allocator),
			{
				20 +
				rl.MeasureTextEx(font(), header_text_c, FONT_SIZE, 1).x +
				45 +
				rl.MeasureTextEx(font(), viewer_info_c, FONT_SIZE, 1).x,
				15,
			},
			FONT_SIZE,
			0,
			rl.RAYWHITE,
		)

		draw_notification()
		rl.EndDrawing()
	}
	if g_loader_thread != nil
	{
		thread.join(g_loader_thread)
		thread.destroy(g_loader_thread)
	}

	// Cleanup
	for g_channel_count > 0
	{disconnect_channel(0)}

	stop_status_poller()
	if g_font_loaded
	{rl.UnloadFont(g_font); g_font_loaded = false}
	rl.CloseAudioDevice()
	rl.CloseWindow()
}
