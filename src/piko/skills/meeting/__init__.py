"""Meeting skill — recorded call to speaker-labelled transcript.

The Swift side records two raw mono tracks (`mic.pcm`, `system.pcm`, 16 kHz
signed 16-bit) into one folder per meeting. This package turns that pair into
playable audio and a transcript where every segment knows who spoke, without
diarization: "me" is whatever was loud on the microphone track, "them" is
whatever was loud on the system-audio track.
"""
