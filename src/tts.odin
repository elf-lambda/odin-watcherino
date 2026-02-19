package main

import "core:fmt"
import os "core:os/os2"
import "core:strings"
import rl "vendor:raylib"

@(private = "file")
g_current_sound: rl.Sound
@(private = "file")
g_sound_loaded: bool

TTS_BASE_PATH :: "tts/"

tts_play :: proc(base_path: string, name: string, volume: int)
{
	path := fmt.tprintf("%s%s.wav", base_path, name)

	if g_sound_loaded
	{
		rl.StopSound(g_current_sound)
		rl.UnloadSound(g_current_sound)
		g_sound_loaded = false
	}
	sound := rl.LoadSound(strings.clone_to_cstring(path, context.temp_allocator))
	if sound.frameCount == 0
	{
		fmt.printf("[tts] Failed to load: %s\n", path)
		return
	}

	vol := clamp(f32(volume) / 100.0, 0, 1)
	rl.SetSoundVolume(sound, vol)
	rl.PlaySound(sound)
	// rl.UnloadSound(sound)

	g_current_sound = sound
	g_sound_loaded = true
}

tts_cleanup :: proc()
{
	if g_sound_loaded
	{
		rl.StopSound(g_current_sound)
		rl.UnloadSound(g_current_sound)
		g_sound_loaded = false
	}
}

tts_generate :: proc()
{
	fmt.println("[tts] Running generate_tts.bat...")

	result, err := os.process_start({command = {"./generate_tts.bat"}})

	// if result.exit_code != 0
	// {
	// 	fmt.printf("[tts] generate_tts.bat failed (exit=%d)\n", result.exit_code)
	// }
	//  else
	// {
	// 	fmt.println("[tts] done.")
	// }
}
