class_name MusicLibrary
extends Resource

@export var tracks: Array[MusicTrack] = []


func find_track(id: StringName) -> MusicTrack:
	for track in tracks:
		if track != null and track.id == id:
			return track
	return null
