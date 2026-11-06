# Exercise the production loop, viewport and pacing rather than a second loop.
extends "res://main.gd"

func _ready():
	benchmark_frames = 18000
	benchmark_scene = 7 # SCENE_FG (the old test actually ran the title loop)
	var args = OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--frames": benchmark_frames = int(args[i + 1])
	super._ready()
