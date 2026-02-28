all:
	odin build 3d_player.odin -file -out:headphones_3d_player_wav_mp3.exe -o:speed

clean:
	rm -f ./headphones_3d_player_wav_mp3.exe ./my_tubes_sound.exe

run:
	./headphones_3d_player_wav_mp3.exe bla.mp3



tubes_sound:
	odin build tubes_sound.odin -file -out:my_tubes_sound.exe -o:speed

run_tubes_sound:
	./my_tubes_sound.exe
