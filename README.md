# Headphones 3D Player in Odin
It takes a music WAV or MP3 file that is listenned on headphones, from a sound inside your head into a holographic, 3D wide stage like a 3D speakers sound in front of you in the same headphones.

## Desciption
This simple program that has 2 modes, the first one the has a player of MP3 and WAV files with 3D speaker like on headphones, that holografic, with a wide stage and music in front of you, instead inside your head. <br>
The second mode is to process a music WAV file that is normally more or less inside your head, depending if you are leastening with planar magnetics or dynamic headphones, and puts the sound in a 3D stage in front of you. You can tune the parameters for your head size and for you headphones.<br>
I tryed with HIFIman Edition XS and with Beyerdynamics DT990 Pro. And both of them, at least to my ears become better with this effect, and much less tiaring when used for a long time.
This is made in the Odin programming language and uses the miniaudio API that already comes with Odin, I developed and tested it on Linux.
In the player mode it can make the following sound simulations:

1. ```--3d_stage```
2. ```--3d_stage_and_tubes```
3. ```--no_3d_stage_and_tubes```
4. ```--original```

## Usage

```
==>> For the player:

  Usage:
    ./headphones_3d_player.exe  bla.mp3 --3d_stage
    ./headphones_3d_player.exe  bla.mp3 --3d_stage_and_tubes
    ./headphones_3d_player.exe  bla.wav --no_3d_stage_and_tubes
    ./headphones_3d_player.exe  bla.wav --original

    ./headphones_3d_player.exe  bla.mp3 --3d_stage              --holographic 0.5 --stage 0.35 --crossfeed 0.5
    ./headphones_3d_player.exe  bla.wav --3d_stage_and_tubes    --holographic 0.5 --stage 0.35 --crossfeed 0.5
    ./headphones_3d_player.exe  bla.wav --no_3d_stage_and_tubes --holographic 0.5 --stage 0.35 --crossfeed 0.5
    ./headphones_3d_player.exe  bla.wav --original              --holographic 0.5 --stage 0.35 --crossfeed 0.5

==>> For processing a WAV file and generating a different output file:

  Usage:
    ./headphone_3d_player.exe  input_file.wav output_file.wav

```

## The 3 parameters that you can change are

```
holographic_effect : f64 = 0.5  // -1.0 to 1.0 ( Depth / Head physics )
soundstage_effect  : f64 = 0.4  // -1.0 to 1.0 ( Width / Mid-Side ratio )
crossfeed_level    : f64 = 0.4  
```

## Controls inside Player

```
Press each input key or value followed by an enter.

   Press "q" or "Q" to quit.
   Press "1" to shift to pos 10 %, can be 0 to 9.
   Press "33" to shift to pos 33 %, can be 2 digits of 01 to 99.
   Press Left Arrow to shift current offset 10 seconds less.
   Press Right Arrow to shift current offset 10 seconds more.
```

## The audio processing pipeline

### The High-Precision Audio Engine ( Data Conversion )
Audio files store data in whole numbers ( integers ), but doing complex math on integers ruins the sound quality due to rounding errors. <br>

The bytes_to_f64 and f64_to_bytes functions are the gatekeepers. They read the raw 16, 24, or 32-bit integer chunks and convert them into 64-bit floating-point numbers ( f64 ) ranging from ``` -1.0 to +1.0 ```. <br>
<br>
The 24-bit Magic: 24-bit audio is tricky because computers process data in chunks of 8, 16, or 32. The code manually stitches three 8-bit bytes together and uses a bitwise check ```(if val & 0x800000 != 0)``` to determine if the audio wave is in the negative phase, perfectly preserving the studio master quality. <br>

### Soundstage Processing ( Mid, Side Matrix )
Before doing any crossfeed, the program alters the perceived width of the room using the soundstage_effect variable. <br>
<br>
It splits the Left and Right channels into "Mid" ( what is identical in both ears, like the lead vocals ) and "Side" ( what is different, like wide guitars or room reverb ). <br>

```
Formulas for Mid/Side:
Mid  = ( Sample_L + Sample_R ) / 2.0
Side = ( Sample_L - Sample_R ) / 2.0
```

Next, it applies your custom gains. Because your soundstage_effect is 0.3, it boosts the Side volume by ``` 12% ( 0.3 * 0.4 ) ``` and dips the Mid volume by ``` 3% ( 0.3 * 0.1 ) ```. <br>
<br>
Finally, it reconstructs the Left and Right channels:

```
Stage_L = ( Mid * Mid_Gain ) + ( Side * Side_Gain )
Stage_R = ( Mid * Mid_Gain ) - ( Side * Side_Gain )
```

### The Delay Line ( Interaural Time Difference )
To make the sound "holographic," the brain needs timing cues. If a sound comes from the left, it hits your left ear first, and your right ear a fraction of a millisecond later. <br>
<br>
The DelayLine struct creates a "Ring Buffer." It acts like a bucket line:

- It reads the oldest audio sample out of the bucket.
- It puts the brand-new audio sample into that exact spot.
- It moves to the next bucket.

- Based on the holographic_effect of 0.5, the calculated delay is exactly 0.000325 seconds (325 microseconds), which simulates the exact time it takes for sound to wrap around an average human head.

### The Low-Pass Filter ( Head Shadowing )
The head is a physical obstacle. It blocks high frequencies ( like cymbals ) from wrapping around to the opposite ear, but lets low frequencies ( like bass guitars ) pass through easily. <br>
<br>
The Filter struct uses a "1-Pole Infinite Impulse Response ( IIR )" formula to muffle the delayed audio. Based on your 0.5 holographic setting, the cutoff frequency is set to 550 Hz. <br>
<br>
```
Formula for the Filter Coefficients:

b1 = exp( -2.0 * PI * cutoff_freq / sample_rate )
a0 = 1.0 - b1

Formula for Filtering the Audio:

Output = ( Input * a0 ) + ( Previous_Output * b1 )

```

### The Final Mix ( Crossfeed )
The main loop ties everything together frame by frame. <br>
<br>
It takes the widened Stage_L, runs it through the Delay, runs that delayed signal through the Filter, and creates Cross_L. It does the same for the right side to create Cross_R. <br>
<br>
Finally, it mixes the opposite channel's muffled, delayed signal into the main ear, scales it by the crossfeed_level (0.4), and lowers the master volume ( 0.85 ) so the added sound doesn't cause digital clipping.
<br>
```
Formula for the Final Mix:
Out_L = ( Stage_L + ( Cross_R * Crossfeed_Level ) ) * Master_Gain
Out_R = ( Stage_R + ( Cross_L * Crossfeed_Level ) ) * Master_Gain
```

## How to compile

```
make clean
make
```

## License
MIT Open Source License

## Have fun
Best regards, <br>
Joao Carvalho
