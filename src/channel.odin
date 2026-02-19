package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

DisplayMessage :: struct
{
	username:    string,
	content:     string,
	color:       string,
	timestamp:   i64,
	highlighted: bool,
}

MAX_CHANNELS :: 64
MAX_MSGS_PER_CHANNEL :: 256
STATUS_POLL_INTERVAL :: 60

ChannelState :: struct
{
	name:              string,
	client:            ^TwitchClient,
	messages:          [MAX_MSGS_PER_CHANNEL]DisplayMessage,
	message_count:     int,
	write_index:       int,
	scroll_offset:     int,
	auto_scroll:       bool,
	connected:         bool,
	connecting:        bool,
	is_live:           bool,
	live_status_known: bool,
	was_live:          bool,
	was_highlighted:   bool,
	tts:               bool,
	viewer_count:      int,
	mu:                sync.Mutex,
}

g_channels: [MAX_CHANNELS]ChannelState
g_channels_mu: sync.Mutex
g_channel_count: int
g_selected_idx: int = -1


// -------------------------------------------------------
// Helpers
// -------------------------------------------------------

@(private = "file")
matches_filter :: proc(content: string) -> bool
{
	lower := strings.to_lower(content, context.temp_allocator)

	for i in 0 ..< len(g_Config.settings.filter)
	{
		f := g_Config.settings.filter[i]
		if len(f) == 0
		{break}
		 else
		{
			if strings.contains(lower, strings.to_lower(f, context.temp_allocator))
			{return true}
		}
	}

	return false
}

push_system_message :: proc(ch: ^ChannelState, text: string, color: string)
{
	sync.mutex_lock(&ch.mu)
	defer sync.mutex_unlock(&ch.mu)
	ch.messages[ch.write_index] = DisplayMessage \
	{
		username  = "System",
		content   = strings.clone(text),
		color     = strings.clone(color),
		timestamp = unix_now(),
	}
	ch.write_index = (ch.write_index + 1) % MAX_MSGS_PER_CHANNEL
	if ch.message_count < MAX_MSGS_PER_CHANNEL
	{ch.message_count += 1}
}

// -------------------------------------------------------
// IRC callbacks
// -------------------------------------------------------

@(private = "file")
on_channel_message :: proc(msg: Message, user_data: rawptr)
{
	ch := (^ChannelState)(user_data)
	dm := DisplayMessage \
	{
		username    = strings.clone(msg.username),
		content     = strings.clone(msg.content),
		color       = strings.clone(msg.user_color),
		timestamp   = msg.timestamp,
		highlighted = matches_filter(msg.content),
	}
	sync.mutex_lock(&ch.mu)
	ch.messages[ch.write_index] = dm
	ch.write_index = (ch.write_index + 1) % MAX_MSGS_PER_CHANNEL
	if ch.message_count < MAX_MSGS_PER_CHANNEL
	{ch.message_count += 1}
	if dm.highlighted
	{ch.was_highlighted = true}
	sync.mutex_unlock(&ch.mu)

	if dm.highlighted
	{
		fmt.printf("[highlight] %s in %s: %s\n", dm.username, ch.name, dm.content)
		tts_play(TTS_BASE_PATH, "ding", 20)
	}
}

@(private = "file")
on_channel_error :: proc(err: string, user_data: rawptr)
{
	ch := (^ChannelState)(user_data)
	fmt.printf("[%s] %s\n", ch.name, err)
}

// -------------------------------------------------------
// Connect thread
// -------------------------------------------------------

ConnectArgs :: struct
{
	index: int,
}

@(private = "file")
connect_thread_proc :: proc(t: ^thread.Thread)
{
	args := (^ConnectArgs)(t.data)
	idx := args.index
	free(args)

	ch := &g_channels[idx]
	client := client_new(ch.name)
	client.on_message = on_channel_message
	client.on_error = on_channel_error
	client.user_data = ch

	if client_connect(client)
	{
		ch.client = client
		ch.connected = true
		client_start(client)
		push_system_message(ch, "Connected. Waiting for messages...", "#6BFF6B")
		fmt.printf("[channel] connected: %s\n", ch.name)
	}
	 else
	{
		client_free(client)
		push_system_message(ch, "Failed to connect.", "#FF6B6B")
		fmt.printf("[channel] connect failed: %s\n", ch.name)
	}
	ch.connecting = false
}

// -------------------------------------------------------
// Public API
// -------------------------------------------------------

add_channel :: proc(name: string, tts := false) -> int
{
	sync.mutex_lock(&g_channels_mu)
	defer sync.mutex_unlock(&g_channels_mu)

	if g_channel_count >= MAX_CHANNELS do return -1

	clean := name
	if len(clean) > 0 && clean[0] == '#' do clean = clean[1:]

	for i in 0 ..< g_channel_count
	{
		if strings.equal_fold(g_channels[i].name, clean)
		{
			return i
		}
	}

	idx := g_channel_count
	g_channel_count += 1

	ch := &g_channels[idx]
	ch^ = {}
	ch.name = strings.clone(clean)
	ch.tts = tts
	ch.auto_scroll = true
	ch.connecting = true
	ch.viewer_count = -1

	if g_selected_idx < 0 do g_selected_idx = idx

	push_system_message(ch, "Connecting...", "#AAAAAA")

	args := new(ConnectArgs)
	args.index = idx
	t := thread.create(connect_thread_proc)
	t.data = args
	thread.start(t)
	// thread.destroy(t)

	return idx
}

disconnect_channel :: proc(idx: int)
{
	sync.mutex_lock(&g_channels_mu)
	defer sync.mutex_unlock(&g_channels_mu)

	if idx < 0 || idx >= g_channel_count do return

	ch := &g_channels[idx]
	if ch.client != nil
	{
		client_free(ch.client)
		ch.client = nil
	}

	// Shift channels down
	for i in idx ..< g_channel_count - 1
	{
		g_channels[i] = g_channels[i + 1]
	}

	g_channel_count -= 1
	mem.zero(&g_channels[g_channel_count], size_of(ChannelState))

	if g_selected_idx >= g_channel_count
	{
		g_selected_idx = g_channel_count - 1
	}
}
get_messages_for_display :: proc(ch: ^ChannelState, out: []DisplayMessage) -> int
{
	sync.mutex_lock(&ch.mu)
	defer sync.mutex_unlock(&ch.mu)
	count := min(ch.message_count, len(out))
	if ch.message_count < MAX_MSGS_PER_CHANNEL
	{
		for i in 0 ..< count
		{out[i] = ch.messages[i]}
		return count
	}
	read := ch.write_index
	for i in 0 ..< count
	{
		out[i] = ch.messages[read]
		read = (read + 1) % MAX_MSGS_PER_CHANNEL
	}
	return count
}

// -------------------------------------------------------
// Status poller
// -------------------------------------------------------

@(private = "file")
g_stop_poller: bool
@(private = "file")
g_poller_thread: ^thread.Thread

@(private = "file")
poller_proc :: proc(t: ^thread.Thread)
{
	time.sleep(1 * time.Second)
	for !g_stop_poller
	{
		sync.mutex_lock(&g_channels_mu)
		count := g_channel_count
		sync.mutex_unlock(&g_channels_mu)

		for i in 0 ..< count
		{
			if g_stop_poller do break

			sync.mutex_lock(&g_channels_mu)
			if i >= g_channel_count
			{
				sync.mutex_unlock(&g_channels_mu)
				break
			}
			name := strings.clone(g_channels[i].name, context.temp_allocator)
			sync.mutex_unlock(&g_channels_mu)

			is_live, viewers := stream_check_status(name)

			sync.mutex_lock(&g_channels[i].mu)
			ch := &g_channels[i]
			prev_live := ch.was_live
			ch.is_live = is_live
			ch.viewer_count = viewers
			ch.was_live = is_live
			ch.live_status_known = true
			sync.mutex_unlock(&g_channels[i].mu)

			if is_live && !prev_live
			{
				fmt.printf("[tts] %s just went live\n", name)
				tts_play(TTS_BASE_PATH, name, 20)
			}

			time.sleep(10 * time.Millisecond)
		}

		// Cooldown 60s
		for _ in 0 ..< STATUS_POLL_INTERVAL
		{
			if g_stop_poller do break
			time.sleep(1 * time.Second)
		}
	}
}

start_status_poller :: proc()
{
	g_stop_poller = false
	g_poller_thread = thread.create(poller_proc)
	thread.start(g_poller_thread)
}

stop_status_poller :: proc()
{
	g_stop_poller = true
	if g_poller_thread != nil
	{
		thread.join(g_poller_thread)
		thread.destroy(g_poller_thread)
		g_poller_thread = nil
	}
}
