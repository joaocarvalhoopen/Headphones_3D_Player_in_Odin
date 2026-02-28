all:
	odin build . -out:headphones_3d_player_wav_mp3.exe -o:speed

clean:
	rm -f ./headphones_3d_player_wav_mp3.exe

run:
	./headphones_3d_player_wav_mp3.exe bla.mp3
