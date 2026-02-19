package main

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

IRC_SERVER :: "irc.chat.twitch.tv"
IRC_PORT :: 6667
RING_BUFFER_CAP :: 256
MAX_TAGS :: 32

Tag :: struct
{
	key:   string,
	value: string,
}

Message :: struct
{
	username:   string,
	content:    string,
	channel:    string,
	user_color: string,
	raw_data:   string,
	timestamp:  i64,
	tags:       [MAX_TAGS]Tag,
	tag_count:  int,
}

MessageCallback :: #type proc(msg: Message, user_data: rawptr)
ErrorCallback :: #type proc(err: string, user_data: rawptr)

RingBuffer :: struct
{
	messages: [RING_BUFFER_CAP]Message,
	write:    int,
	count:    int,
	mu:       sync.Mutex,
}

TwitchClient :: struct
{
	socket:        net.TCP_Socket,
	channel:       string,
	ring:          RingBuffer,
	on_message:    MessageCallback,
	on_error:      ErrorCallback,
	user_data:     rawptr,
	listen_thread: ^thread.Thread,
	mu:            sync.Mutex,
	connected:     bool,
	stopped:       bool,
	recv_buf:      [8192]u8,
	recv_len:      int,
	allocator:     runtime.Allocator,
}

// ============================================================
// Utility
// ============================================================

unix_now :: proc() -> i64
{
	return time.now()._nsec / 1_000_000_000
}

color_ensure_visible :: proc(hex: string, allocator := context.allocator) -> string
{
	h := hex
	if len(h) > 0 && h[0] == '#'
	{h = h[1:]}
	if len(h) != 6
	{return strings.clone("#FFFFFF", allocator)}

	parse_hex2 :: proc(s: string) -> int
	{
		v, _ := strconv.parse_int(s, 16)
		return v
	}
	r := parse_hex2(h[0:2])
	g := parse_hex2(h[2:4])
	b := parse_hex2(h[4:6])

	if 0.299 * f64(r) + 0.587 * f64(g) + 0.114 * f64(b) < 128
	{
		r += int(f64(255 - r) * 0.4)
		g += int(f64(255 - g) * 0.4)
		b += int(f64(255 - b) * 0.4)
	}
	return strings.clone(fmt.tprintf("#%02X%02X%02X", r, g, b), allocator)
}

default_color_for_user :: proc(username: string, allocator := context.allocator) -> string
{
	colors := [?]string {
		"#FF0000",
		"#0000FF",
		"#00FF00",
		"#B22222",
		"#FF7F50",
		"#9ACD32",
		"#FF4500",
		"#2E8B57",
		"#DAA520",
		"#D2691E",
		"#5F9EA0",
		"#1E90FF",
		"#FF69B4",
		"#8A2BE2",
		"#00FF7F",
	}
	lower := strings.to_lower(username, context.temp_allocator)
	h := 0
	for c in lower
	{h = h * 31 + int(c)}
	if h < 0
	{h = -h}
	return strings.clone(colors[h % len(colors)], allocator)
}

find_tag :: proc(msg: ^Message, key: string) -> (string, bool)
{
	for i in 0 ..< msg.tag_count
	{
		if msg.tags[i].key == key
		{return msg.tags[i].value, true}
	}
	return "", false
}

// ============================================================
// Ring buffer
// ============================================================

ring_add :: proc(rb: ^RingBuffer, msg: Message)
{
	sync.mutex_lock(&rb.mu)
	defer sync.mutex_unlock(&rb.mu)
	rb.messages[rb.write] = msg
	rb.write = (rb.write + 1) % RING_BUFFER_CAP
	if rb.count < RING_BUFFER_CAP
	{rb.count += 1}
}

ring_get_all :: proc(rb: ^RingBuffer, out: []Message) -> int
{
	sync.mutex_lock(&rb.mu)
	defer sync.mutex_unlock(&rb.mu)
	count := min(rb.count, len(out))
	start := (rb.write - count + RING_BUFFER_CAP) % RING_BUFFER_CAP
	for i in 0 ..< count
	{
		out[i] = rb.messages[(start + i) % RING_BUFFER_CAP]
	}
	return count
}

// ============================================================
// IRC parsing
// ============================================================

parse_tags :: proc(data: string, msg: ^Message, allocator := context.allocator)
{
	if len(data) == 0 || data[0] != '@'
	{return}
	space := strings.index_byte(data, ' ')
	if space < 0
	{return}
	parts := strings.split(data[1:space], ";", context.temp_allocator)
	for part in parts
	{
		if msg.tag_count >= MAX_TAGS
		{break}
		eq := strings.index_byte(part, '=')
		if eq < 0
		{continue}
		msg.tags[msg.tag_count] = Tag \
		{
			key   = strings.clone(part[:eq], allocator),
			value = strings.clone(part[eq + 1:], allocator),
		}
		msg.tag_count += 1
	}
}

parse_privmsg :: proc(data: string, allocator := context.allocator) -> (Message, bool)
{
	msg := Message \
	{
		timestamp = unix_now(),
		raw_data  = strings.clone(data, allocator),
	}
	parse_tags(data, &msg, allocator)

	privmsg_pos := strings.index(data, " PRIVMSG ")
	if privmsg_pos < 0
	{return {}, false}
	after := data[privmsg_pos + len(" PRIVMSG "):]

	colon_space := strings.index(after, " :")
	if colon_space < 0
	{return {}, false}
	msg.channel = strings.clone(after[:colon_space], allocator)
	msg.content = strings.clone(after[colon_space + 2:], allocator)

	if dn, ok := find_tag(&msg, "display-name"); ok && len(dn) > 0
	{
		msg.username = strings.clone(dn, allocator)
	}
	 else
	{
		prefix := data
		if len(data) > 0 && data[0] == '@'
		{
			if sp := strings.index_byte(data, ' '); sp >= 0
			{prefix = data[sp + 1:]}
		}
		if len(prefix) > 0 && prefix[0] == ':'
		{
			rest := prefix[1:]
			if bang := strings.index_byte(rest, '!'); bang >= 0
			{
				msg.username = strings.clone(rest[:bang], allocator)
			}
		}
	}

	if color, ok := find_tag(&msg, "color"); ok && len(color) > 0
	{
		msg.user_color = color_ensure_visible(color, allocator)
	}
	 else
	{
		msg.user_color = default_color_for_user(msg.username, allocator)
	}
	return msg, true
}

message_free :: proc(msg: ^Message, allocator := context.allocator)
{
	delete(msg.username, allocator)
	delete(msg.content, allocator)
	delete(msg.channel, allocator)
	delete(msg.user_color, allocator)
	delete(msg.raw_data, allocator)
	for i in 0 ..< msg.tag_count
	{
		delete(msg.tags[i].key, allocator)
		delete(msg.tags[i].value, allocator)
	}
}

// ============================================================
// Socket helpers
// ============================================================

send_irc_line :: proc(socket: net.TCP_Socket, line: string) -> bool
{
	buf := fmt.tprintf("%s\r\n", line)
	n, err := net.send_tcp(socket, transmute([]u8)buf)
	return err == nil && n == len(buf)
}

recv_line :: proc(client: ^TwitchClient, out: []u8) -> (int, bool)
{
	for
	{
		for i in 0 ..< client.recv_len
		{
			if client.recv_buf[i] == '\n'
			{
				end := i
				if end > 0 && client.recv_buf[end - 1] == '\r'
				{end -= 1}
				n := min(end, len(out) - 1)
				mem.copy(&out[0], &client.recv_buf[0], n)
				out[n] = 0
				consumed := i + 1
				client.recv_len -= consumed
				if client.recv_len > 0
				{
					mem.copy(&client.recv_buf[0], &client.recv_buf[consumed], client.recv_len)
				}
				return n, true
			}
		}
		space := len(client.recv_buf) - 1 - client.recv_len
		if space <= 0
		{client.recv_len = 0; space = len(client.recv_buf) - 1}
		n, err := net.recv_tcp(
			client.socket,
			client.recv_buf[client.recv_len:client.recv_len + space],
		)
		if err != nil || n == 0
		{return 0, false}
		client.recv_len += n
	}
}

// ============================================================
// Internal helpers
// ============================================================

push_system_msg :: proc(client: ^TwitchClient, text: string, color: string)
{
	msg := Message \
	{
		username   = "System",
		content    = strings.clone(text, client.allocator),
		channel    = strings.clone(client.channel, client.allocator),
		user_color = strings.clone(color, client.allocator),
		timestamp  = unix_now(),
	}
	ring_add(&client.ring, msg)
	if client.on_message != nil
	{client.on_message(msg, client.user_data)}
}

_do_connect :: proc(client: ^TwitchClient) -> bool
{
	ep, ep_err := net.resolve_ip4(fmt.tprintf("%s:%d", IRC_SERVER, IRC_PORT))
	if ep_err != nil
	{fmt.eprintln("[twitch] resolve:", ep_err); return false}

	socket, dial_err := net.dial_tcp(ep)
	if dial_err != nil
	{fmt.eprintln("[twitch] dial:", dial_err); return false}
	client.socket = socket

	nick := fmt.tprintf("justinfan%d", rand.int_max(8999) + 1000)
	if !send_irc_line(socket, fmt.tprintf("NICK %s", nick))
	{net.close(socket); return false}
	if !send_irc_line(socket, fmt.tprintf("JOIN %s", client.channel))
	{net.close(socket); return false}
	if !send_irc_line(socket, "CAP REQ :twitch.tv/tags twitch.tv/commands")
	{net.close(socket); return false}

	sync.mutex_lock(&client.mu)
	client.connected = true
	client.stopped = false
	sync.mutex_unlock(&client.mu)
	return true
}

// ============================================================
// Listen thread  (t.data is the Odin field, not t.user_data)
// ============================================================

_listen_proc :: proc(t: ^thread.Thread)
{
	client := (^TwitchClient)(t.data) // <-- .data not .user_data
	line_buf: [4096]u8
	reconnect_delay := 2

	for
	{
		sync.mutex_lock(&client.mu)
		stopped := client.stopped
		sync.mutex_unlock(&client.mu)
		if stopped
		{break}

		n, ok := recv_line(client, line_buf[:])
		if !ok
		{
			sync.mutex_lock(&client.mu)
			was_stopped := client.stopped
			sync.mutex_unlock(&client.mu)
			if was_stopped
			{break}

			err_str := fmt.tprintf("Connection lost. Reconnecting in %ds...", reconnect_delay)
			if client.on_error != nil
			{client.on_error(err_str, client.user_data)}
			push_system_msg(client, err_str, "#FF6B6B")

			time.sleep(time.Duration(reconnect_delay) * time.Second)
			client.recv_len = 0

			if _do_connect(client)
			{
				reconnect_delay = 2
				push_system_msg(client, "Reconnected successfully.", "#6BFF6B")
				if client.on_error != nil
				{client.on_error("Reconnected", client.user_data)}
			}
			 else
			{
				switch
				{
				case reconnect_delay < 5:
					reconnect_delay = 5
				case reconnect_delay < 10:
					reconnect_delay = 10
				case reconnect_delay < 30:
					reconnect_delay = 30
				case:
					reconnect_delay = 60
				}
				if client.on_error != nil
				{client.on_error("Reconnect failed, will retry", client.user_data)}
			}
			continue
		}

		reconnect_delay = 2
		line := string(line_buf[:n])

		if line == "PING :tmi.twitch.tv"
		{
			send_irc_line(client.socket, "PONG :tmi.twitch.tv")
			continue
		}

		if strings.contains(line, "PRIVMSG")
		{
			if msg, parsed := parse_privmsg(line, client.allocator); parsed
			{
				ring_add(&client.ring, msg)
				if client.on_message != nil
				{client.on_message(msg, client.user_data)}
			}
		}
	}

	sync.mutex_lock(&client.mu)
	client.connected = false
	sync.mutex_unlock(&client.mu)
}

// ============================================================
// Public API
// ============================================================

client_new :: proc(channel: string, allocator := context.allocator) -> ^TwitchClient
{
	c := new(TwitchClient, allocator)
	c^ = {}
	c.allocator = allocator
	if len(channel) > 0 && channel[0] != '#'
	{
		c.channel = strings.clone(fmt.tprintf("#%s", channel), allocator)
	}
	 else
	{
		c.channel = strings.clone(channel, allocator)
	}
	return c
}

client_connect :: proc(client: ^TwitchClient) -> bool
{return _do_connect(client)}

client_start :: proc(client: ^TwitchClient)
{
	t := thread.create(_listen_proc)
	t.data = client
	client.listen_thread = t
	thread.start(t)
}

client_stop :: proc(client: ^TwitchClient)
{
	sync.mutex_lock(&client.mu)
	if client.stopped
	{sync.mutex_unlock(&client.mu); return}
	client.stopped = true
	client.connected = false
	net.close(client.socket)
	sync.mutex_unlock(&client.mu)
	if client.listen_thread != nil
	{
		thread.join(client.listen_thread)
		thread.destroy(client.listen_thread)
		client.listen_thread = nil
	}
}

client_free :: proc(client: ^TwitchClient)
{
	client_stop(client)
	delete(client.channel, client.allocator)
	free(client, client.allocator)
}

client_is_connected :: proc(client: ^TwitchClient) -> bool
{
	sync.mutex_lock(&client.mu)
	defer sync.mutex_unlock(&client.mu)
	return client.connected
}

client_get_all_messages :: proc(client: ^TwitchClient, out: []Message) -> int
{
	return ring_get_all(&client.ring, out)
}
