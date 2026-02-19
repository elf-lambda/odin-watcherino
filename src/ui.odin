package main

import "core:fmt"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

FONT_SIZE :: 16
MESSAGE_VERTICAL_GAP :: 4

g_font: rl.Font
g_font_loaded: bool
g_sidebar_minimized: bool

font :: #force_inline proc() -> rl.Font
{
	return g_font if g_font_loaded else rl.GetFontDefault()
}

// -------------------------------------------------------
// Notification
// -------------------------------------------------------

Notification :: struct
{
	text:      string,
	show_time: f32,
	active:    bool,
}
g_notification: Notification

show_notification :: proc(text: string)
{
	g_notification = \
	{
		text      = text,
		show_time = f32(rl.GetTime()),
		active    = true,
	}
}

draw_notification :: proc()
{
	if !g_notification.active
	{return}
	elapsed := f32(rl.GetTime()) - g_notification.show_time
	duration :: f32(2.0)
	if elapsed > duration
	{g_notification.active = false; return}

	alpha := u8(255)
	if elapsed > duration - 0.5
	{
		alpha = u8(255 * (1 - (elapsed - (duration - 0.5)) / 0.5))
	}
	f := font()
	text_c := strings.clone_to_cstring(g_notification.text, context.temp_allocator)
	text_sz := rl.MeasureTextEx(f, text_c, FONT_SIZE, 1)
	box_w := text_sz.x + 40
	box_h := text_sz.y + 20
	box_x := (f32(rl.GetScreenWidth()) - box_w) / 2
	box_y := f32(70)
	box := rl.Rectangle{box_x, box_y, box_w, box_h}

	rl.DrawRectangle(
		i32(box_x + 2),
		i32(box_y + 2),
		i32(box_w),
		i32(box_h),
		{0, 0, 0, u8(f32(alpha) * 0.3)},
	)
	rl.DrawRectangleRounded(box, 0.3, 8, {50, 50, 70, alpha})
	rl.DrawRectangleRoundedLines(box, 0.3, 8, {100, 100, 255, alpha})
	rl.DrawTextEx(
		f,
		text_c,
		{box_x + (box_w - text_sz.x) / 2, box_y + (box_h - text_sz.y) / 2},
		FONT_SIZE,
		1,
		{255, 255, 255, alpha},
	)
}

// -------------------------------------------------------
// Helpers
// -------------------------------------------------------

hex_to_color :: proc(hex: string) -> rl.Color
{
	h := hex
	if len(h) == 0
	{return rl.WHITE}
	if h[0] == '#'
	{h = h[1:]}
	if len(h) < 6
	{return rl.WHITE}
	p :: proc(s: string) -> u8
	{
		v: u8
		for c in s[:2]
		{
			v <<= 4
			switch
			{
			case c >= '0' && c <= '9':
				v |= u8(c - '0')
			case c >= 'a' && c <= 'f':
				v |= u8(c - 'a' + 10)
			case c >= 'A' && c <= 'F':
				v |= u8(c - 'A' + 10)
			}
		}
		return v
	}
	return {p(h[0:]), p(h[2:]), p(h[4:]), 255}
}

get_message_line_count :: proc(msg: ^DisplayMessage, content_max_w: f32) -> int
{
	f := font()
	u_cstr := strings.clone_to_cstring(msg.username, context.temp_allocator)
	u_w := rl.MeasureTextEx(f, u_cstr, FONT_SIZE, 0).x
	sep_w := rl.MeasureTextEx(f, ": ", FONT_SIZE, 0).x
	sp_w := rl.MeasureTextEx(f, " ", FONT_SIZE, 0).x

	lines := 1
	cur_w := content_max_w - (u_w + sep_w)
	text := msg.content

	for len(text) > 0
	{
		// skip spaces
		for len(text) > 0 && text[0] == ' '
		{text = text[1:]}
		if len(text) == 0
		{break}

		// find word end
		end := 0
		for end < len(text) && text[end] != ' ' && text[end] != '\n'
		{end += 1}
		word := strings.clone_to_cstring(text[:end], context.temp_allocator)
		w_w := rl.MeasureTextEx(f, word, FONT_SIZE, 0).x
		text = text[end:]

		if w_w > cur_w
		{
			lines += 1
			cur_w = content_max_w - (w_w + sp_w)
		}
		 else
		{
			cur_w -= w_w + sp_w
		}
	}
	return lines
}

// -------------------------------------------------------
// Channel item / list
// -------------------------------------------------------

draw_minimize_button :: proc(bounds: rl.Rectangle, minimized: bool) -> bool
{
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, bounds)
	clicked := hovered && rl.IsMouseButtonPressed(.LEFT)
	f := font()
	rl.DrawRectangleRounded(
		bounds,
		0.3,
		4,
		rl.Color{50, 50, 70, 255} if hovered else {35, 35, 45, 255},
	)
	rl.DrawRectangleLinesEx(bounds, 1, rl.PURPLE if hovered else rl.Color{60, 60, 60, 255})
	icon := cstring("<<") if minimized else ">>"
	ts := rl.MeasureTextEx(f, icon, FONT_SIZE, 0)
	rl.DrawTextEx(
		f,
		icon,
		{bounds.x + (bounds.width - ts.x) / 2, bounds.y + (bounds.height - ts.y) / 2},
		FONT_SIZE,
		0,
		rl.RAYWHITE,
	)
	return clicked
}

draw_channel_item :: proc(
	bounds: rl.Rectangle,
	name: string,
	selected: bool,
	is_live: bool,
	live_known: bool,
	has_highlight: bool,
) -> bool
{
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, bounds)
	clicked := hovered && rl.IsMouseButtonPressed(.LEFT)
	f := font()

	bg: rl.Color
	switch
	{case has_highlight:
		bg = {60, 20, 20, 255}; case selected:
		bg = {60, 60, 80, 255}; case hovered:
		bg = {45, 45, 45, 255}; case:
		bg = {30, 30, 30, 255}}
	rl.DrawRectangleRec(bounds, bg)

	border: rl.Color
	switch
	{case has_highlight:
		border = {180, 40, 40, 255}; case selected:
		border = rl.PURPLE; case:
		border = {50, 50, 50, 255}}
	rl.DrawRectangleLinesEx(bounds, 1, border)

	rl.DrawTextEx(
		f,
		strings.clone_to_cstring(name, context.temp_allocator),
		{bounds.x + 10, bounds.y + bounds.height / 2 - 8},
		FONT_SIZE,
		0,
		rl.RAYWHITE,
	)

	dot: rl.Color
	switch
	{case !live_known:
		dot = {100, 100, 100, 255}; case is_live:
		dot = {50, 220, 50, 255}; case:
		dot = {220, 50, 50, 255}}
	rl.DrawCircleV({bounds.x + bounds.width - 15, bounds.y + bounds.height / 2}, 5, dot)
	return clicked
}

@(private = "file")
g_list_scroll: int

draw_channel_list :: proc(
	bounds: rl.Rectangle,
	names: []string,
	is_live: []bool,
	live_known: []bool,
	has_highlight: []bool,
	selected_idx: int,
	toggle_minimize: ^bool,
) -> int
{
	count := len(names)
	f := font()
	rl.DrawRectangleRec(bounds, {25, 25, 25, 255})
	rl.DrawRectangleLinesEx(bounds, 1, {40, 40, 40, 255})
	rl.DrawTextEx(f, "CHANNELS", {bounds.x + 10, bounds.y + 10}, FONT_SIZE, 1, rl.WHITE)

	btn := rl.Rectangle{bounds.x + bounds.width - 50, bounds.y + 8, 40, 20}
	if draw_minimize_button(btn, false)
	{toggle_minimize^ = true}

	// Sort live-unknown-offline, alpha within groups
	sorted: [MAX_CHANNELS]int
	sc := 0

	alpha_sort :: proc(arr: []int, names: []string)
	{
		for i := 1; i < len(arr); i += 1
		{
			tmp := arr[i]; j := i - 1
			for j >= 0 && names[arr[j]] > names[tmp]
			{arr[j + 1] = arr[j]; j -= 1}
			arr[j + 1] = tmp
		}
	}
	ls := sc; for i in 0 ..< count
	{if live_known[i] && is_live[i]
		{sorted[sc] = i; sc += 1}}; alpha_sort(sorted[ls:sc], names)
	us := sc; for i in 0 ..< count
	{if !live_known[i]
		{sorted[sc] = i; sc += 1}}; alpha_sort(sorted[us:sc], names)
	os := sc; for i in 0 ..< count
	{if live_known[i] && !is_live[i]
		{sorted[sc] = i; sc += 1}}; alpha_sort(sorted[os:sc], names)

	item_h := f32(32); gap := f32(4)
	list_top := bounds.y + 35; list_h := bounds.height - 35
	slot_h := item_h + gap
	visible := int(list_h / slot_h)
	max_sc := max(sc - visible, 0)

	if rl.CheckCollisionPointRec(rl.GetMousePosition(), bounds)
	{
		w := rl.GetMouseWheelMove()
		if w != 0
		{g_list_scroll = clamp(g_list_scroll - int(w), 0, max_sc)}
	}
	g_list_scroll = min(g_list_scroll, max_sc)

	clicked := -1
	rl.BeginScissorMode(i32(bounds.x), i32(list_top), i32(bounds.width), i32(list_h))
	for si in g_list_scroll ..< sc
	{
		i := sorted[si]
		item_y := list_top + f32(si - g_list_scroll) * slot_h
		if item_y + item_h > bounds.y + bounds.height
		{break}
		r := rl.Rectangle{bounds.x + 5, item_y, bounds.width - 10, item_h}
		if draw_channel_item(
			r,
			names[i],
			i == selected_idx,
			is_live[i],
			live_known[i],
			has_highlight[i],
		)
		{clicked = i}
	}
	rl.EndScissorMode()

	if max_sc > 0
	{
		thumb_h := max(f32(visible) / f32(sc) * list_h, 20)
		thumb_y := list_top + f32(g_list_scroll) / f32(max_sc) * (list_h - thumb_h)
		tx := i32(bounds.x + bounds.width - 5)
		rl.DrawRectangle(tx, i32(list_top), 3, i32(list_h), {35, 35, 35, 255})
		rl.DrawRectangle(tx, i32(thumb_y), 3, i32(thumb_h), {80, 80, 80, 255})
	}
	return clicked
}

draw_minimized_channel_list :: proc(bounds: rl.Rectangle) -> bool
{
	rl.DrawRectangleRec(bounds, {25, 25, 25, 255})
	rl.DrawRectangleLinesEx(bounds, 1, {40, 40, 40, 255})
	clicked := draw_minimize_button({bounds.x + 5, bounds.y + 5, bounds.width - 10, 30}, true)
	rl.DrawTextEx(
		font(),
		"C\nH\nA\nN",
		{bounds.x + bounds.width / 2 - 5, bounds.y + 50},
		FONT_SIZE - 2,
		0,
		{150, 150, 150, 255},
	)
	return clicked
}

// -------------------------------------------------------
// Input box
// -------------------------------------------------------

draw_input_box :: proc(bounds: rl.Rectangle, buf: ^[256]u8, focused: bool)
{
	f := font()
	rl.DrawRectangleRec(bounds, {25, 25, 25, 255})
	rl.DrawRectangleLinesEx(bounds, 1, rl.PURPLE if focused else rl.Color{50, 50, 50, 255})

	s := string(cstring(&buf[0]))
	if focused
	{
		key := rl.GetCharPressed()
		for key > 0
		{
			n := len(s)
			if n < 255 && key >= 32 && key <= 125
			{buf[n] = u8(key); buf[n + 1] = 0; s = string(cstring(&buf[0]))}
			key = rl.GetCharPressed()
		}
		if rl.IsKeyPressed(.BACKSPACE)
		{
			n := len(s)
			if n > 0
			{buf[n - 1] = 0; s = string(cstring(&buf[0]))}
		}
	}

	text_y := bounds.y + bounds.height / 2 - 9
	if len(s) == 0 && !focused
	{
		rl.DrawTextEx(
			f,
			"Type /command or message...",
			{bounds.x + 10, text_y},
			FONT_SIZE,
			1,
			rl.WHITE,
		)
	}
	 else
	{
		c := strings.clone_to_cstring(s, context.temp_allocator)
		rl.DrawTextEx(f, c, {bounds.x + 10, text_y}, FONT_SIZE, 1, rl.RAYWHITE)
		if focused && int(rl.GetTime() * 2) % 2 == 0
		{
			tw := rl.MeasureTextEx(f, c, 20, 1).x
			rl.DrawRectangle(
				i32(bounds.x + 12 + tw),
				i32(bounds.y + 10),
				2,
				i32(bounds.height - 20),
				rl.PURPLE,
			)
		}
	}
}

// -------------------------------------------------------
// Chat panel
// -------------------------------------------------------

@(private = "file")
g_chat_dragging: bool
@(private = "file")
g_chat_drag_offset: f32

draw_chat :: proc(
	bounds: rl.Rectangle,
	messages: []DisplayMessage,
	scroll_offset: ^int,
	auto_scroll: ^bool,
)
{
	f := font()
	padding := f32(15)
	sb_w := f32(10)
	content_w := bounds.width - padding * 2 - sb_w
	line_h := f32(FONT_SIZE + MESSAGE_VERTICAL_GAP)

	// count total lines
	total_lines := 0
	for i in 0 ..< len(messages)
	{total_lines += get_message_line_count(&messages[i], content_w)}

	lines_on_screen := int(bounds.height / line_h)
	max_scroll := max(total_lines - lines_on_screen, 0)

	// checks
	mouse := rl.GetMousePosition()
	in_chat := rl.CheckCollisionPointRec(mouse, bounds)
	wheel := rl.GetMouseWheelMove()

	// only scroll if in area FIX
	if in_chat && wheel != 0
	{
		if (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL))
		{
			if wheel < 0
			{
				scroll_offset^ = max_scroll
				auto_scroll^ = true
			}
		}
		 else
		{
			scroll_offset^ -= int(wheel * 3)
			auto_scroll^ = (scroll_offset^ >= max_scroll)
		}
	}

	// scroll
	hH := max(f32(lines_on_screen) / f32(max(total_lines, 1)) * bounds.height, f32(30))
	s_range := bounds.height - hH
	s_pct := f32(scroll_offset^) / f32(max(max_scroll, 1))
	s_handle := rl.Rectangle {
		bounds.x + bounds.width - sb_w - 2,
		bounds.y + s_pct * s_range,
		sb_w,
		hH,
	}

	// chat panel scroll drag
	if total_lines > 0 &&
	   rl.CheckCollisionPointRec(mouse, s_handle) &&
	   rl.IsMouseButtonPressed(.LEFT)
	{
		g_chat_dragging = true
		g_chat_drag_offset = mouse.y - s_handle.y
	}

	if g_chat_dragging
	{
		if rl.IsMouseButtonDown(.LEFT)
		{
			auto_scroll^ = false
			new_y := mouse.y - g_chat_drag_offset
			scroll_offset^ = int(((new_y - bounds.y) / s_range) * f32(max_scroll))
		}
		 else
		{
			g_chat_dragging = false
		}
	}

	if auto_scroll^ do scroll_offset^ = max_scroll
	scroll_offset^ = clamp(scroll_offset^, 0, max_scroll)


	rl.DrawRectangleRec(bounds, {20, 20, 20, 255})
	rl.DrawRectangleLinesEx(bounds, 1, {40, 40, 40, 255})

	rl.BeginScissorMode(i32(bounds.x), i32(bounds.y), i32(bounds.width), i32(bounds.height))

	line_counter := 0
	for i in 0 ..< len(messages)
	{
		msg := &messages[i]
		msg_lines := get_message_line_count(msg, content_w)

		if line_counter + msg_lines > scroll_offset^
		{
			msg_y := bounds.y + f32(line_counter - scroll_offset^) * line_h
			msg_h := f32(msg_lines) * line_h
			mb := rl.Rectangle{bounds.x + padding, msg_y, content_w, msg_h}

			hovered := in_chat && rl.CheckCollisionPointRec(mouse, mb)
			clicked := hovered && rl.IsMouseButtonPressed(.LEFT)

			if hovered && msg_y >= bounds.y && msg_y + msg_h <= bounds.y + bounds.height
			{
				rl.DrawRectangleRec(mb, {35, 35, 35, 180})
			}

			if msg.highlighted
			{
				rl.DrawRectangleLinesEx(
					{mb.x - 2, mb.y - 1, mb.width + 4, mb.height + 2},
					1.5,
					{220, 50, 50, 200},
				)
				rl.DrawRectangleRec(mb, {80, 20, 20, 60})
			}

			if clicked
			{
				ts := time.unix(msg.timestamp, 0)
				h, m, s := time.clock_from_time(ts)
				copied := fmt.tprintf(
					"[%02d:%02d:%02d] %s: %s",
					h,
					m,
					s,
					msg.username,
					msg.content,
				)
				rl.SetClipboardText(strings.clone_to_cstring(copied, context.temp_allocator))
				show_notification("Message Copied!")
			}

			u_col := hex_to_color(msg.color)
			u_cstr := strings.clone_to_cstring(msg.username, context.temp_allocator)
			u_w := rl.MeasureTextEx(f, u_cstr, FONT_SIZE, 0).x
			sp_w := rl.MeasureTextEx(f, " ", FONT_SIZE, 0).x

			ts := time.unix(msg.timestamp, 0)
			h, m, s_clk := time.clock_from_time(ts)
			time_c := strings.clone_to_cstring(
				fmt.tprintf("[%02d:%02d:%02d] ", h, m, s_clk),
				context.temp_allocator,
			)

			tptr := msg.content
			for sub in 0 ..< msg_lines
			{
				g_idx := line_counter + sub
				if g_idx < scroll_offset^
				{
					// text processing logic for skipping lines
					l_max := (sub == 0) ? (content_w - u_w - 15) : content_w
					ux := f32(0)
					for len(tptr) > 0
					{
						for len(tptr) > 0 && tptr[0] == ' ' do tptr = tptr[1:]
						if len(tptr) == 0 do break
						end := 0
						for end < len(tptr) && tptr[end] != ' ' && tptr[end] != '\n' do end += 1
						word_w :=
							rl.MeasureTextEx(f, strings.clone_to_cstring(tptr[:end], context.temp_allocator), FONT_SIZE, 0).x
						tptr = tptr[end:]
						if ux + word_w > l_max && ux > 0 do break
						ux += word_w + sp_w
					}
					continue
				}

				dy := bounds.y + f32(g_idx - scroll_offset^) * line_h
				if dy > bounds.y + bounds.height do break
				dx := bounds.x + padding

				if sub == 0
				{
					t_w := rl.MeasureTextEx(f, time_c, FONT_SIZE, 0).x
					rl.DrawTextEx(f, time_c, {dx, dy}, FONT_SIZE, 0, {100, 100, 100, 255})
					rl.DrawTextEx(f, u_cstr, {dx + t_w, dy}, FONT_SIZE, 0, u_col)
					rl.DrawTextEx(f, ": ", {dx + t_w + u_w, dy}, FONT_SIZE, 0, rl.LIGHTGRAY)
					dx += t_w + u_w + rl.MeasureTextEx(f, ": ", FONT_SIZE, 0).x
				}

				l_max := (sub == 0) ? ((bounds.x + padding + content_w) - dx) : content_w
				ux := f32(0)
				for len(tptr) > 0
				{
					for len(tptr) > 0 && tptr[0] == ' ' do tptr = tptr[1:]
					if len(tptr) == 0 do break
					end := 0
					for end < len(tptr) && tptr[end] != ' ' && tptr[end] != '\n' do end += 1
					wc := strings.clone_to_cstring(tptr[:end], context.temp_allocator)
					ww := rl.MeasureTextEx(f, wc, FONT_SIZE, 0).x
					tptr = tptr[end:]
					if ux + ww > l_max && ux > 0 do break
					rl.DrawTextEx(f, wc, {dx + ux, dy}, FONT_SIZE, 0, rl.RAYWHITE)
					ux += ww + sp_w
				}
			}
		}
		line_counter += msg_lines
	}
	rl.EndScissorMode()

	if total_lines > 0
	{
		rl.DrawRectangle(
			i32(bounds.x + bounds.width - sb_w - 2),
			i32(bounds.y),
			i32(sb_w),
			i32(bounds.height),
			{25, 25, 25, 255},
		)
		rl.DrawRectangleRounded(
			s_handle,
			0.4,
			4,
			rl.GRAY if g_chat_dragging else rl.Color{60, 60, 60, 255},
		)
	}
}
