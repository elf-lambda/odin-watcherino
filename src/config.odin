package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

CONFIG_MAX_CHANNELS :: 64
CONFIG_MAX_FILTER_ENTRIES :: 32

AppConfig :: struct
{
	nick:         string,
	oauth:        string,
	filter:       [CONFIG_MAX_FILTER_ENTRIES]string,
	filter_count: int,
	recording:    bool,
	archivedir:   string,
	ttspath:      string,
	ttsmessage:   string,
}

ChannelConfig :: struct
{
	name: string,
	tts:  bool,
}

Config :: struct
{
	settings:      AppConfig,
	channels:      [CONFIG_MAX_CHANNELS]ChannelConfig,
	channel_count: int,
}

config_load :: proc(path: string, cfg: ^Config) -> bool
{
	data, ok := os.read_entire_file(path)
	if !ok
	{
		fmt.eprintf("[config] Could not open '%s'\n", path)
		return false
	}
	defer delete(data)

	content := string(data)
	line_num := 0

	for line in strings.split_lines_iterator(&content)
	{
		line_num += 1
		trimmed := strings.trim_space(line)

		if len(trimmed) == 0 || trimmed[0] == '#'
		{
			continue
		}

		eq_idx := strings.index_byte(trimmed, '=')
		if eq_idx == -1
		{
			fmt.eprintf("[config] Line %d: missing '=', skipping\n", line_num)
			continue
		}

		key := strings.trim_space(trimmed[:eq_idx])
		val := strings.trim_space(trimmed[eq_idx + 1:])

		if strings.has_prefix(key, "$")
		{
			k := key[1:]
			switch k
			{
			case "nick":
				cfg.settings.nick = strings.clone(val)
			case "oauth":
				cfg.settings.oauth = strings.clone(val)
			case "archivedir":
				cfg.settings.archivedir = strings.clone(val)
			case "ttspath":
				cfg.settings.ttspath = strings.clone(val)
			case "ttsmessage":
				cfg.settings.ttsmessage = strings.clone(val)
			case "recording":
				cfg.settings.recording = (val == "true")
			case "filter":
				// split CSV
				parts := strings.split(val, ",")
				count := 0
				for p in parts
				{
					if count < CONFIG_MAX_FILTER_ENTRIES
					{
						cfg.settings.filter[count] = strings.clone(strings.trim_space(p))
						count += 1
					}
				}
				cfg.settings.filter_count = count
			case:
				fmt.eprintf("[config] Line %d: unknown setting '$%s'\n", line_num, k)
			}
		}
		 else
		{
			if cfg.channel_count < CONFIG_MAX_CHANNELS
			{
				ch := &cfg.channels[cfg.channel_count]
				ch.name = strings.clone(key)
				ch.tts = (val == "true")
				cfg.channel_count += 1
			}
			 else
			{
				fmt.eprintf("[config] Line %d: max channels reached\n", line_num)
			}
		}
	}

	return true
}

config_print :: proc(cfg: ^Config)
{
	fmt.printf("=== Config ===\n")
	fmt.printf("  nick:       %s\n", cfg.settings.nick)
	fmt.printf("  recording:  %s\n", cfg.settings.recording ? "true" : "false")
	fmt.printf("  archivedir: %s\n", cfg.settings.archivedir)
	fmt.printf("  ttspath:    %s\n", cfg.settings.ttspath)
	fmt.printf("  ttsmessage: %s\n", cfg.settings.ttsmessage)
	fmt.printf("  filter (%d): ", cfg.settings.filter_count)
	for i in 0 ..< cfg.settings.filter_count
	{
		fmt.printf("%s ", cfg.settings.filter[i])
	}
	fmt.printf("\n  channels (%d):\n", cfg.channel_count)
	for i in 0 ..< cfg.channel_count
	{
		fmt.printf("    %s (tts=%s)\n", cfg.channels[i].name, cfg.channels[i].tts ? "yes" : "no")
	}
}
