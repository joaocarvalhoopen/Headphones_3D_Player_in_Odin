/*

# How to compile

   make clean
   make


# Usage

  ==>> For the player:
  Usage:
      ./headphone_3d_player.exe  bla.mp3
      ./headphone_3d_player.exe  bla.wav
      ./headphone_3d_player.exe  bla.mp3 --holographic 0.5 --stage 0.35 --crossfeed 0.5
      ./headphone_3d_player.exe  bla.wav --holographic 0.5 --stage 0.35 --crossfeed 0.5

  ==>> For processing a WAV file and generating a different output file:
  Usage:
      ./headphone_3d_player.exe  input_file.wav output_file.wav




The audio processing pipeline:

1. The High-Precision Audio Engine ( Data Conversion )
Audio files store data in whole numbers ( integers ), but doing complex math
on integers ruins the sound quality due to rounding errors.

The bytes_to_f64 and f64_to_bytes functions are the gatekeepers. They read the
raw 16, 24, or 32-bit integer chunks and convert them into 64-bit floating-point
numbers ( f64 ) ranging from -1.0 to +1.0.

The 24-bit Magic: 24-bit audio is tricky because computers process data in chunks
of 8, 16, or 32. The code manually stitches three 8-bit bytes together and uses a
bitwise check (if val & 0x800000 != 0) to determine if the audio wave is in the
negative phase, perfectly preserving the studio master quality.

2. Soundstage Processing ( Mid / Side Matrix )
Before doing any crossfeed, the program alters the perceived width of the room
using the soundstage_effect variable.

It splits the Left and Right channels into "Mid" ( what is identical in both ears,
like the lead vocals ) and "Side" ( what is different, like wide guitars or room reverb ).

Formulas for Mid/Side:
Mid  = ( Sample_L + Sample_R ) / 2.0
Side = ( Sample_L - Sample_R ) / 2.0

Next, it applies your custom gains. Because your soundstage_effect is 0.3, it boosts the
Side volume by 12% ( 0.3 * 0.4 ) and dips the Mid volume by 3% ( 0.3 * 0.1 ).
Finally, it reconstructs the Left and Right channels:

Stage_L = ( Mid * Mid_Gain ) + ( Side * Side_Gain )
Stage_R = ( Mid * Mid_Gain ) - ( Side * Side_Gain )

3. The Delay Line ( Interaural Time Difference )
To make the sound "holographic," the brain needs timing cues. If a sound comes from the left,
it hits your left ear first, and your right ear a fraction of a millisecond later.

The DelayLine struct creates a "Ring Buffer." It acts like a bucket line:

It reads the oldest audio sample out of the bucket.

It puts the brand-new audio sample into that exact spot.

It moves to the next bucket.

Based on the holographic_effect of 0.5, the calculated delay is exactly 0.000325 seconds
(325 microseconds), which simulates the exact time it takes for sound to wrap around an
average human head.

4. The Low-Pass Filter ( Head Shadowing )
The head is a physical obstacle. It blocks high frequencies ( like cymbals ) from wrapping
around to the opposite ear, but lets low frequencies ( like bass guitars ) pass through easily.

The Filter struct uses a "1-Pole Infinite Impulse Response ( IIR )" formula to muffle the
delayed audio. Based on your 0.5 holographic setting, the cutoff frequency is set to 550 Hz.

Formula for the Filter Coefficients:
b1 = exp( -2.0 * PI * cutoff_freq / sample_rate )
a0 = 1.0 - b1

Formula for Filtering the Audio:
Output = ( Input * a0 ) + ( Previous_Output * b1 )

5. The Final Mix ( Crossfeed )
The main loop ties everything together frame by frame.

It takes the widened Stage_L, runs it through the Delay, runs that delayed signal through the
Filter, and creates Cross_L. It does the same for the right side to create Cross_R.

Finally, it mixes the opposite channel's muffled, delayed signal into the main ear, scales it by
the crossfeed_level (0.4), and lowers the master volume ( 0.85 ) so the added sound doesn't cause
digital clipping.

Formula for the Final Mix:
Out_L = ( Stage_L + ( Cross_R * Crossfeed_Level ) ) * Master_Gain
Out_R = ( Stage_R + ( Cross_L * Crossfeed_Level ) ) * Master_Gain

*/

package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:math"
import "core:strconv"
import "core:mem"

import ma "vendor:miniaudio"

// Custom struct to pass our fully loaded buffer to the callback
Audio_Data :: struct {

	buffer   : [ ]f32,
	cursor   : u64,
	channels : u32,
}

data_callback :: proc "c" ( device      : ^ma.device,
	                        output      : rawptr,
							input       : rawptr,
						    frame_count : u32 ) {

	// Retrieve our custom context
	ctx := ( ^Audio_Data )( device.pUserData )
	if ctx == nil do return

	frames_to_write := u64( frame_count )
	total_frames    := u64( len( ctx.buffer ) ) / u64( ctx.channels )
	frames_left     := total_frames - ctx.cursor

	// Stop playing if we've reached the end of our buffer
	if frames_left == 0 do return

	// Clamp frames so we don't read past the end of our slice
	if frames_to_write > frames_left {

		frames_to_write = frames_left
	}

	// Calculate pointers
	out_ptr  := cast( [ ^ ]f32 )output
	in_slice := ctx.buffer[ctx.cursor * u64( ctx.channels ) : ]

	// Copy data from our buffer into miniaudio's output buffer
	bytes_to_copy := int( frames_to_write * u64( ctx.channels ) ) * size_of( f32 )
	mem.copy( out_ptr, raw_data( in_slice ), bytes_to_copy )

	// Advance the play cursor
	ctx.cursor += frames_to_write
}

main :: proc() {

	start_offset_perc : f64 = 0.0

	args := runtime.args__

	// Process WAV file case.
	if len( args ) == 3 {

		process_file_main( )
		// We will terminate here.
		os.exit( 0 )
	}


	if len( args ) < 2 {

		fmt.printfln( "\nERROR : No input WAV or MP3 file." )
		print_usage( )
		os.exit( -1 )
	}

	if len( args ) > 3 && len( args ) < 8 || len( args ) > 8  {

		fmt.printfln( "\nERROR : Invalid or incomplete number of parameters." )
		print_usage( )
		os.exit( -1 )
	}

	// Player case

	filename := args[ 1 ]

	// Magnetostatics HIfiman Edition XS

    holographic_effect : f64 = 0.5   // 0.5  // 0.6   // 0.5   // -1.0 to 1.0 (Depth / Head physics)
    soundstage_effect  : f64 = 0.35  // 0.4  // 0.4            // -1.0 to 1.0 (Width / Mid-Side ratio)
    crossfeed_level    : f64 = 0.5   // 0.5  // 0.5  // 0.6 // 0.4


    // Beyerdynamic DT990 Pro

    // holographic_effect : f64 = 0.5  // 0.5     // -1.0 to 1.0 (Depth / Head physics)
    // soundstage_effect  : f64 = 0.2  // 0.4     // -1.0 to 1.0 (Width / Mid-Side ratio)
    // crossfeed_level    : f64 = 0.4  // 0.6  // 0.4


    print_usage :: proc ( ) {

        fmt.printfln( "\n==>> For the player:" )
        fmt.printfln( "\n  Usage:" )
        fmt.printfln( "    ./headphones_3d_player.exe  bla.mp3" )
        fmt.printfln( "    ./headphones_3d_player.exe  bla.wav" )
        fmt.printfln( "    ./headphones_3d_player.exe  bla.mp3 --holographic 0.5 --stage 0.35 --crossfeed 0.5" )
        fmt.printfln( "    ./headphones_3d_player.exe  bla.wav --holographic 0.5 --stage 0.35 --crossfeed 0.5" )

        fmt.printfln( "\n==>> For processing a WAV file:" )
        fmt.printfln( "\n  Usage:" )
        fmt.printfln( "    ./headphones_3d_player.exe  input_file.wav output_file.wav\n" )
    }

    // Player case with custom parameters.
	if len( args ) == 8 {

		for i := 2; i < 7; i += 1 {

			my_tag  := args[ i ]
			val_str := string( args[ i + 1 ] )
			switch my_tag {

				case "--holographic" :

					val_f64, ok := strconv.parse_f64( val_str )
					if ok {

						holographic_effect = val_f64
						// fmt.printfln( "--holographic %f", holographic_effect )
					} else {

						fmt.printfln( "\nERROR : parsing --holographic %s", val_str )
					    print_usage( )
						os.exit( -1 )
					}
					i += 1

				case "--stage" :

					val_f64, ok := strconv.parse_f64( val_str )
					if ok {

						soundstage_effect = val_f64
						// fmt.printfln( "--stage %f", soundstage_effect )
					} else {

						fmt.printfln( "\nERROR : parsing --stage %s", val_str )
						print_usage( )
						os.exit( -1 )
					}
					i += 1

				case "--crossfeed" :

					val_f64, ok := strconv.parse_f64( val_str )
					if ok {

						crossfeed_level = val_f64
						// fmt.printfln( "--crossfeed %f", crossfeed_level )
					} else {

						fmt.printfln( "\nERROR : parsing --crossfeed %s", val_str )
						print_usage( )
						os.exit( -1 )
					}
					i += 1

				case :
					fmt.printfln( "\nERROR: cmd line parsing unknown %s", val_str )
					print_usage( )
                    os.exit( -1 )
			}
		}

	}


	// 2. Force decoder config to output .f32 for easy math filtering
	decoder_config := ma.decoder_config_init( .f32, 0, 0 )

	decoder : ma.decoder
	if ma.decoder_init_file( filename, & decoder_config, & decoder ) != .SUCCESS {

		fmt.printfln( "\nERROR : Could not load file: %s\n", filename )
		os.exit( -2 )
	}

	// Save format details before uninitializing the decoder
	channels    := decoder.outputChannels
	sample_rate := decoder.outputSampleRate

	bits_per_sample : int = 0

	#partial switch decoder.outputFormat {

		case ma.format.s16:
			bits_per_sample = 16

		case ma.format.s24:
			bits_per_sample = 24

		case ma.format.s32:
			bits_per_sample = 32

		case ma.format.u8:
			bits_per_sample = 8

		case ma.format.f32:
			bits_per_sample = 32
	}

	fmt.printfln( "\nDetected %v-bit audio at %v Hz.\n",
                  bits_per_sample, sample_rate )

    fmt.printfln( "Applying DSP... \n    Holographic : %.2f | Soundstage : %.2f | Crossfeed : %.2f\n",
                  holographic_effect,
                  soundstage_effect,
                  crossfeed_level )


	// 3. Find out how long the file is and allocate our memory
	length_in_frames : u64
	if ma.decoder_get_length_in_pcm_frames( & decoder, & length_in_frames ) != .SUCCESS {

		fmt.printfln( "Could not get length of the audio file." )
		os.exit( -3 )
	}

	total_samples := length_in_frames * u64( channels )
	full_buffer := make( [ ]f32, total_samples )

	// 4. Read the entire file into our buffer at once
	frames_read : u64
	if ma.decoder_read_pcm_frames( & decoder, raw_data( full_buffer ), length_in_frames, & frames_read ) != .SUCCESS {

		fmt.printfln( "Could not read PCM frames." )
		os.exit( -4 )
	}

	// We have the data! We no longer need the decoder.
	ma.decoder_uninit( & decoder )

	// 5. Processing Stage
	fmt.printfln( "Loaded file. Applying filter to %v samples...", total_samples )

/*
	// 5. Halve the volume
	for i in 0 ..< total_samples {

		sample := full_buffer[ i ]

	    // Filter
		sample *= 0.5

		full_buffer[ i ] = sample
	}
*/

	audio_data_in  := full_buffer
	audio_data_out : [ ]f32 = processing_3d_audio_space( holographic_effect,
                                				         soundstage_effect,
							                             crossfeed_level,
							                             int( sample_rate ),
							                             int( total_samples ),
							                             audio_data_in )

	delete( full_buffer ) // Remember to free the memory later!
    full_buffer = audio_data_out
    defer delete( full_buffer )





	fmt.println( "\n3D Space filter applied successfully.\n" )

	// 6. Setup our custom data context
	audio_ctx := Audio_Data {

		buffer   = full_buffer[ : frames_read * u64( channels ) ],
		cursor   = 0,
		channels = channels,
	}

	// 7. Setup playback
	device_config := ma.device_config_init( .playback )
	device_config.playback.format   = .f32            // Match the forced decoder format
	device_config.playback.channels = channels
	device_config.sampleRate        = sample_rate
	device_config.dataCallback      = data_callback
	device_config.pUserData         = & audio_ctx    // Pass our struct!

	device: ma.device
	if ma.device_init( nil, & device_config, & device ) != .SUCCESS {

		fmt.printfln( "\nERROR : Failed to open playback device." )
		os.exit( -5 )
	}

	if ma.device_start( & device ) != .SUCCESS {

		fmt.eprintfln( "\nERROR : Failed to start playback device." )
		ma.device_uninit( & device )
		os.exit( -6 )
	}

	keys_manual : string = \
`Press each input key or value followed by an enter.

   Press "q" or "Q" to quit.
   Press "1" to shift to pos 10 %, can be 0 to 9.
   Press "33" to shift to pos 33 %, can be 2 digits of 01 to 99.
   Press Left Arrow to shift current offset 10 seconds less.
   Press Right Arrow to shift current offset 10 seconds more.`

	fmt.println( keys_manual )
	fmt.printf( "\n\n" )

	// p : [ 1 ]byte
	// os.read( os.stdin, p[ : ] )

	for {

		p : [ 2 ]byte
		os.read( os.stdin, p[ : ] )


		my_char     : rune = rune( p[ 0 ] )
		my_char_int : int = int( my_char )


		// fmt.printfln( "%d", my_char_int )
		switch my_char {

		case '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' :
		    value_f64 : f64 = 0.0
			tmp_str : string
			my_char_2 := rune( p[ 1 ] )
	  		if my_char_2 == '0' ||
			   my_char_2 == '1' ||
			   my_char_2 == '2' ||
			   my_char_2 == '3' ||
			   my_char_2 == '4' ||
			   my_char_2 == '5' ||
			   my_char_2 == '6' ||
			   my_char_2 == '7' ||
			   my_char_2 == '8' ||
			   my_char_2 == '9' {

			    // 2 digits
				tmp_str = fmt.aprintf( "%c%c", my_char, my_char_2 )
				value_int, _ := strconv.parse_int( tmp_str, 10 )
				fmt.printf( "pos %d %% ", value_int )
				value_f64 = f64( value_int ) * 0.01
			} else {

				// 1 digits
				tmp_str = fmt.aprintf( "%c", my_char )
				value_int, _ := strconv.parse_int( tmp_str, 10 )
				fmt.printf( "pos %d %% ", value_int * 10  )
				value_f64 = f64( value_int ) * 0.1
			}

			// value, _ := strconv.parse_int( tmp_str, 10 )
			// fmt.printfln( "%s  pos %d %%", tmp_str, value * 10  )
			audio_ctx.cursor = u64( f64( total_samples ) * 0.5 * value_f64 )
			time_str : string = get_track_time( int( audio_ctx.cursor ),
				                                sample_rate )
            fmt.printfln( "%s", time_str )


		case rune( 68 ) :
			// Left arrow.
			// Shift offset left.
			if audio_ctx.cursor >= u64( sample_rate ) * 10 {

				audio_ctx.cursor = audio_ctx.cursor - u64( sample_rate ) * 10 // 10 seconds

				time_str : string = get_track_time( int( audio_ctx.cursor ),
					                                sample_rate )

				perc : f64 = f64( audio_ctx.cursor ) / f64( total_samples / 2 )
				fmt.printfln( "shift less 10 seconds, position %2.3f %% %s ... ",
				              perc, time_str )
			} else {

				audio_ctx.cursor = 0

				time_str : string = get_track_time( int( audio_ctx.cursor ),
					                                sample_rate )

				perc : f64 = f64( audio_ctx.cursor ) / f64( total_samples / 2 )
				fmt.printfln( "shift to 0 seconds, position %2.3f %% %s ... ",
				              perc, time_str )
			}

		case rune( 67 ) :
			// Right arrow.
			// Shift offset right.
			if audio_ctx.cursor <= ( u64( total_samples ) / 2 ) - u64( sample_rate ) {

            	audio_ctx.cursor = audio_ctx.cursor + u64( sample_rate ) * 10 // 10 seconds

                time_str : string = get_track_time( int( audio_ctx.cursor ),
					                                sample_rate )

                perc : f64 = f64( audio_ctx.cursor ) / f64( total_samples / 2 )
				fmt.printfln( "shift more 10 seconds, position %2.3f %%  %s ... ",
				              perc, time_str )
			}

		case 'q', 'Q':

			fmt.printfln( "\n...have a nice rest of day.\n" )
	        ma.device_uninit( & device )
		    os.exit( 0 )
		}

	}



	ma.device_uninit( & device )
}

get_track_time :: proc ( cur_pos     : int,
	                     sample_rate : u32 ) ->
                       ( track_time : string ) {

    time_sec_f64    : f64 =  f64( cur_pos ) / f64( sample_rate )
    time_in_sec_int := int( math.round_f64( time_sec_f64 ) )

    hours        : int = int( ( time_sec_f64 / 60 ) / 60 )
    rest_minutes : int = int( time_sec_f64 / 60 ) - hours * 60
    minutes      : int = rest_minutes
    rest_seconds : int = int( time_sec_f64 ) - minutes * 60 - hours * 60

    track_time = fmt.aprintf( "  %dH %dM %dS", hours, minutes, rest_seconds )
	return track_time
}

//
// ------------------------------------------------
//

processing_3d_audio_space :: proc ( holographic_effect  : f64,
                                    soundstage_effect   : f64,
                                    crossfeed_level     : f64,
                                    sample_rate         : int,
                                    total_num_samples   : int,
                                    audio_data_in       : [ ]f32 ) ->
                                  ( audio_data_out : [ ]f32 ) {

    delay_time := 0.00025 + (holographic_effect * 0.00015)

    delay_samples := int( f64( sample_rate) * delay_time )

    // Base cutoff is 700Hz. Holographic scales it from 1000Hz (-1.0) to 400Hz (+1.0)
    cutoff_freq := 700.0 - (holographic_effect * 300.0)
    master_gain : f64 = 0.85

    delay_L_to_R : DelayLine
    delay_R_to_L : DelayLine
    init_delay( & delay_L_to_R, delay_samples )
    init_delay( & delay_R_to_L, delay_samples )
    defer delete( delay_L_to_R.buffer )
    defer delete( delay_R_to_L.buffer )

    filter_L_to_R : Filter
    filter_R_to_L : Filter
    init_filter( & filter_L_to_R, cutoff_freq, f64( sample_rate ) )
    init_filter( & filter_R_to_L, cutoff_freq, f64( sample_rate ) )

    num_frames  := total_num_samples / 2

    audio_data_out = make( [ ]f32, len( audio_data_in ) )

    for i := 0; i < num_frames; i += 1 {

        idx_L := i * 2
        idx_R := ( i * 2 + 1 )

        // Read to 64-bit float
        sample_L := f64( audio_data_in[ idx_L ] )
        sample_R := f64( audio_data_in[ idx_R ] )

        // Soundstage Processing ( Mid / Side )
        mid  := ( sample_L + sample_R ) / 2.0
        side := ( sample_L - sample_R ) / 2.0

        side_gain := 1.0 + ( soundstage_effect * 0.4 ) // Up to 40% wider
        mid_gain  := 1.0 - ( soundstage_effect * 0.1 ) // Slight mid reduction to balance

        stage_L := ( mid * mid_gain ) + ( side * side_gain )
        stage_R := ( mid * mid_gain ) - ( side * side_gain )

        // Holographic Crossfeed Processing
        cross_L := process_filter( & filter_L_to_R, process_delay( & delay_L_to_R, stage_L ) )
        cross_R := process_filter( & filter_R_to_L, process_delay( & delay_R_to_L, stage_R ) )

        out_L := ( stage_L + ( cross_R * crossfeed_level ) ) * master_gain
        out_R := ( stage_R + ( cross_L * crossfeed_level ) ) * master_gain

        // Write back to exact original format
        audio_data_out[ idx_L ] = f32( out_L )
        audio_data_out[ idx_R ] = f32( out_R )
    }

    return audio_data_out
}

//
// ------------------------------------------------
//

// Standard WAV Header
WavHeader :: struct #packed {

    chunk_id        : [ 4 ]u8,
    chunk_size      : u32,
    format          : [ 4 ]u8,
    subchunk1_id    : [ 4 ]u8,
    subchunk1_size  : u32,
    audio_format    : u16,
    num_channels    : u16,
    sample_rate     : u32,
    byte_rate       : u32,
    block_align     : u16,
    bits_per_sample : u16,
    subchunk2_id    : [ 4 ]u8,
    subchunk2_size  : u32,
}

// High Precision Delay Line
DelayLine :: struct {

    buffer : [ ]f64,
    index  : int,
    length : int,
}

init_delay :: proc ( d      : ^DelayLine,
	                 length : int ) {

    if length <= 0 {

    	d.length = 1
    } else {

    	d.length = length
    }
    d.buffer = make( [ ]f64, d.length )
    d.index = 0
}

process_delay :: proc ( d     : ^DelayLine,
	                    input : f64 ) ->
                        f64 {

    output := d.buffer[ d.index ]
    d.buffer[ d.index ] = input
    d.index = ( d.index + 1 ) % d.length
    return output
}

// High Precision 1 Pole Low-Pass Filter
Filter :: struct {

    a0 : f64,
    b1 : f64,
    z1 : f64,
}

init_filter :: proc ( f           : ^Filter,
	                  fc          : f64,
					  sample_rate : f64 ) {

    f.b1 = math.exp( -2.0 * math.PI * fc / sample_rate )
    f.a0 = 1.0 - f.b1
    f.z1 = 0.0
}

process_filter :: proc ( f     : ^Filter,
	                     input : f64 ) ->
                         f64 {

    output := ( input * f.a0 ) + ( f.z1 * f.b1 )
    f.z1 = output
    return output
}

// Converts raw bytes to f64 based on bit depth
bytes_to_f64 :: proc ( bytes     : [ ]u8,
	                   bit_depth : u16 ) ->
                       f64 {

    switch bit_depth {

    case 16:
        val := i16( bytes[ 0 ] ) | ( i16( bytes[ 1 ] ) << 8 )
        return f64(val) / 32768.0

    case 24:
        // 24-bit sign extension magic
        val := i32( bytes[ 0 ] ) | ( i32( bytes[ 1 ] ) << 8 ) | ( i32( bytes[ 2 ] ) << 16 )
        if val & 0x800000 != 0 {

        	val -= 0x1000000
        }
        return f64( val ) / 8388608.0

    case 32:
        val := i32( bytes[ 0 ] ) | ( i32( bytes[ 1 ] ) << 8 ) | ( i32( bytes[ 2 ] ) << 16 ) | ( i32( bytes[ 3 ] ) << 24 )
        return f64( val ) / 2147483648.0

    }

    return 0.0
}

// Converts f64 back to raw bytes
f64_to_bytes :: proc ( val       : f64,
	                   bytes     : [ ]u8,
					   bit_depth : u16 ) {

    clamped := math.clamp( val, -1.0, 0.999999 )
    switch bit_depth {

    case 16:
        out_val := i16( clamped * 32768.0 )
        bytes[ 0 ] = u8( out_val & 0xFF )
        bytes[ 1 ] = u8( ( out_val >> 8 ) & 0xFF )

    case 24:
        out_val := i32( clamped * 8388608.0 )
        bytes[ 0 ] = u8( out_val & 0xFF )
        bytes[ 1 ] = u8( ( out_val >> 8 ) & 0xFF )
        bytes[ 2 ] = u8( ( out_val >> 16 ) & 0xFF )

    case 32:
        out_val := i32( clamped * 2147483648.0 )
        bytes[ 0 ] = u8( out_val & 0xFF )
        bytes[ 1 ] = u8( ( out_val >> 8 ) & 0xFF )
        bytes[ 2 ] = u8( ( out_val >> 16 ) & 0xFF )
        bytes[ 3 ] = u8( ( out_val >> 24 ) & 0xFF )
    }
}

process_file_main :: proc( ) {

	input_file  := "input.wav"
    output_file := "output.wav"


    // Magnetostatics HIfiman Edition XS

    holographic_effect : f64 = 0.5  // 0.6   // 0.5   // -1.0 to 1.0 (Depth / Head physics)
    soundstage_effect  : f64 = 0.4  // 0.4            // -1.0 to 1.0 (Width / Mid-Side ratio)
    crossfeed_level    : f64 = 0.4  // 0.5  // 0.6 // 0.4


    // Beyerdynamic DT990 Pro

    // holographic_effect : f64 = 0.5  // 0.5     // -1.0 to 1.0 (Depth / Head physics)
    // soundstage_effect  : f64 = 0.2  // 0.4     // -1.0 to 1.0 (Width / Mid-Side ratio)
    // crossfeed_level    : f64 = 0.4 // 0.6  // 0.4


    if len( os.args ) == 3 {

    	input_file  = os.args[ 1 ]
    	output_file = os.args[ 2 ]

     	if input_file == output_file {

      		fmt.printfln( "\nERROR : input_file.wav and output_file.wav must be different!" )
            os.exit( -1 )
      	}

    } else {

    	fmt.printfln( "\nUsage:\n    headphones_3d_player_wav_mp3.exe <input_file.wav> <output_file.wav>\n" )
    }

    data, ok := os.read_entire_file( input_file )
    if !ok {

        fmt.printfln( "Error: While reading %s", input_file )
        return
    }
    defer delete( data )

    header := cast( ^WavHeader )raw_data( data )
    if header.num_channels != 2 {

        fmt.printfln("Error : Requires stereo WAV.")
        return
    }

    bytes_per_sample := int( header.bits_per_sample / 8 )
    fmt.printfln( "Detected %v-bit audio at %v Hz.\n",
                  header.bits_per_sample, header.sample_rate )

    // Calculate DSP parameters based on user knobs
    // Base delay is 250us. Holographic scales it from 150us (-1.0) to 350us (+1.0)
    // delay_time := 0.00025 + (holographic_effect * 0.0001)

    delay_time := 0.00025 + (holographic_effect * 0.00015)

    delay_samples := int( f64( header.sample_rate) * delay_time )

    // Base cutoff is 700Hz. Holographic scales it from 1000Hz (-1.0) to 400Hz (+1.0)
    cutoff_freq := 700.0 - (holographic_effect * 300.0)
//  crossfeed_level : f64 = 0.4
    master_gain : f64 = 0.85

    delay_L_to_R : DelayLine
    delay_R_to_L : DelayLine
    init_delay( & delay_L_to_R, delay_samples )
    init_delay( & delay_R_to_L, delay_samples )
    defer delete( delay_L_to_R.buffer )
    defer delete( delay_R_to_L.buffer )

    filter_L_to_R : Filter
    filter_R_to_L : Filter
    init_filter( & filter_L_to_R, cutoff_freq, f64( header.sample_rate ) )
    init_filter( & filter_R_to_L, cutoff_freq, f64( header.sample_rate ) )

    audio_bytes := data[ 44 : ]
    num_samples := len( audio_bytes ) / bytes_per_sample
    num_frames  := num_samples / 2

    output_bytes := make( [ ]u8, len( data ) )
    defer delete( output_bytes )
    mem.copy( & output_bytes[ 0 ], & data[ 0 ], 44 ) // Copy header

    fmt.printfln( "Applying DSP... \n    Holographic : %.2f | Soundstage : %.2f | Crossfeed : %.2f\n",
                  holographic_effect,
                  soundstage_effect,
                  crossfeed_level )

    for i := 0; i < num_frames; i += 1 {

        idx_L := i * 2 * bytes_per_sample
        idx_R := ( i * 2 + 1 ) * bytes_per_sample

        // Read to 64-bit float
        sample_L := bytes_to_f64( audio_bytes[idx_L : idx_L+bytes_per_sample ], header.bits_per_sample )
        sample_R := bytes_to_f64( audio_bytes[idx_R : idx_R+bytes_per_sample ], header.bits_per_sample )

        // Soundstage Processing ( Mid / Side )
        mid  := ( sample_L + sample_R ) / 2.0
        side := ( sample_L - sample_R ) / 2.0

        side_gain := 1.0 + ( soundstage_effect * 0.4 ) // Up to 40% wider
        mid_gain  := 1.0 - ( soundstage_effect * 0.1 ) // Slight mid reduction to balance

        stage_L := ( mid * mid_gain ) + ( side * side_gain )
        stage_R := ( mid * mid_gain ) - ( side * side_gain )

        // Holographic Crossfeed Processing
        cross_L := process_filter( & filter_L_to_R, process_delay( & delay_L_to_R, stage_L ) )
        cross_R := process_filter( & filter_R_to_L, process_delay( & delay_R_to_L, stage_R ) )

        out_L := ( stage_L + ( cross_R * crossfeed_level ) ) * master_gain
        out_R := ( stage_R + ( cross_L * crossfeed_level ) ) * master_gain

        // Write back to exact original format
        f64_to_bytes( out_L, output_bytes[ 44 + idx_L : 44 + idx_L + bytes_per_sample ], header.bits_per_sample )
        f64_to_bytes( out_R, output_bytes[ 44 + idx_R : 44 + idx_R + bytes_per_sample ], header.bits_per_sample )
    }

    os.write_entire_file( output_file, output_bytes )
    fmt.printfln( "Processed file saved to:\n    %s", output_file )
}
