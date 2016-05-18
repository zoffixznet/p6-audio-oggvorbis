#!/usr/bin/perl6
unit class OggVorbis;

use v6.c;

use NativeCall;
use Audio::OggVorbis::Ogg;
use Autio::OggVorbis::Vorbis;
use Autio::OggVorbis::VorbisEnc;

# Used by both encode() and decode()
has  		$!input_data;
has 		$!output_data;
has	uint64	$!input_offset;
has uint64	$!bytes_io;
has 		$!ogg_buffer;
has 		$!output_type;
has Bool    $!initialized;
has 		$!stream_info;

constant BLOCK_SIZE = 4096;

# cw: -XXX-
#
# Think about class interface. If there will not be instances of this 
# class, 
#
# How is the interface supposed to look?
# What options will there be (decode first, encode last)
# What form will the output be in (decode first, encode last)
# Add WAV header output.

method readInputBlock {
	my $block;

	# cw: I'm sure there's a slightly better way to do this.
	given $id {
		when IO::Handle {
			$block = $fh.read(BLOCK_SIZE);
			$bytes_io = $block.elems;
		}

		when Blob {
			my $block_end = $input_offset + BLOCK_SIZE;
			$block_end = $block_end > $id.elems ?? 
				$id.elems !! $block_end;

			$block = Blob.new($id[$!input_offset .. $block_end]);
			$bytes_io = $block_end - $!input_offset;
			$!input_offset += bytes_io;
		}

		default {
			# cw: Raise exception here. 
			die "Invalid input data type.";
		}
	}
	ogg_sync_wrote($oy, $bytes_io);

	# Write data into $!ogg_buffer.
	$!ogg_bufer[$_] = $block[$_] for ^$bytes_io;
}

method writeOutputBlocks(@output_blocks) {
	# cw: 
	# Proper Interleave! Thanks, psch!
	# <psch> m:  my $lol = [(1, 2, 3), (4, 5, 6), (7, 8, 9)]; say [Z](|$lol).flat

	# cw: $!output_data is an array of <output> objects.
	# 		The only time the number of objects in $!output_data is singular
	#		is if we are writing WAV output. Otherwise contents will be 
	#		an array of IO::Handles or Buf objects.

	for $!output_type -> $ot {
		given $!ot {

			when 'wav' {
				# If output type is WAV then we use @interleve_block;
				# cw: -XXX- check to see if [Z] works with CArray
				my @interleve_blocks = [Z](|@output_blocks).flat;
				my $newbuf = Buf[int16].new(@interleve_blocks)
				given $!output_data[0] {
					when IO::Handle {
						$!output_data[0].write($newbuf);
					}

					when Buf {
						$od.push(Buf[int16].new($newbuf);
					}
				}
			}
			
			when 'raw' {
				for @output_blocks:kv -> $c, $b {
					my $block = Buf[int16].new(@$b);
					given $!output_data[$c] {
						when IO::Handle {
							$od.write($block);
						}

						when Buf {
							# cw: infix<~=> would work, but would create EXTRA object
							#     so .push is more
							$od.push($block);
						}
					}
				}
			}

		}
	}
}

method !initialize_output() {
	# No other special initialization if performing WAV decode.
	return if $!output_type eq 'wav';

	my $diff = $stream_info.info.channels - @$!output_data.elems;
	if $diff > 0 {
		given $!output_data[0] {
			when Buf {
				# cw: Create Buf objects
				@$!output_data.push(Buf[int16].new xx $diff);
			}

			when IO::Handle {
				# Open and add IO::Handle objects
				$base = S/'.' \d+$//;

				for (^$diff) -> $d {
					my $fn = $base ~ ".{$d + $num}";

					my $fh = $fh.IO.open(:w, :bin)
						or
					die "Could not open '{$fh}' for writing due to unexpected error.";

					@$!output_data.push($fh); 
				}
			}
		}
	}

}

method !finish_wav {
	# Create and write WAV header.
	my $wav_header = Audio::OggVorbis::WavHeader.new(
		:$file_size($bytes_io),
		:$fmttype(PCM_TYPE),
		:$channels($.stream_info.info.channels),
		:$rate($.stream_info.info.rate,
		:$bps($.stream_info.info.bitrate_nominal)
	).as_buf;

	given $!output_data[0] {
		
		when Buf {
			$_ = $wav_header.push($_);
		}

		when IO::Handle {
			my $final_output_name = $_.path ~~ S/'.' nh$//;
			my $final_output_handle = $final_output_name.IO.open(:w, :bin);

			$final_output_handle.write($wav_header.as_buf);

			# Use sendfile() unless file is over 2G, otherwise use perl fallback.
			if ($bytes_io < 2 ** 32 - 1) {
				my $rv = sendfile (
					$final_output_handle.native-descriptor,
					$_.native_descriptor,
					0,
					$!bytes_io
				);

				if ($rv < 0) {
					my $errno := cglobal('libc.so.6', 'errno', int32)
					die "Unexpected IO error when finalizing WAV output: $errno"; 
				}
			} else {
				$_.seek(0);
				$final_output_handle.write($_.read(BLOCK_SIZE)) 
					while ! $_.eof;
			}
		}

		default {
			die "Unexpected type encountered when finalizing WAV: {$_.^name}";
		}

	}
}

multi method !actual_decode($id, $od, *%opts) {
	$!input_data = $id;
	$!input_offset = 0;
	$!output_type = (%opts<output>:v || 'raw').lc;

	# cw: Check output option. If not 'wav' or 'raw' then throw exception.
	if $!output_type ne 'wav' && $!output_type ne 'raw') {
		# cw: -YYY- Throw proper exception! 
		# InvalidOption
		die "Invalid output type option '{$!output_type}'";
	}

	# cw: Will always be an array ref, although will contain single output 
	#     in the case that OUTPUT option is 'WAV'
	#
	#	  In the case where we are decoding directly into memory, the $od
	#
	$!output_data = [$od];
	$!initialized = False;

	# cw:
	# In the case of large files, we really 
	# don't want to load the whole file into memory.
	# How to do that AND handle the cases where the input 
	# data already resides in a Buf/Blob?
	my ($data, $result, $eos);

	my $oy = ogg_sync_state.new();
	my $os = ogg_stream_state.new();
	my $og = ogg_page.new();
	my $op = ogg_packet.new();
	my $vi = vorbis_info.new();
	my $vc = vorbis_comment.new();
	my $vd = vorbis_dsp_state.new();
	my $vb = vorbis_block.new();

	# cw: Loop in case of chained bitstreams.
	$eos = 0;
	loop {
		$buffer = ogg_sync_buffer($oy, BLOCK_SIZE);
		readInputBlock();

		if (ogg_sync_pageout($oy, $og) != 1) {
			last if $!bytes_io < BLOCK_SIZE;
			
			die "Not an Ogg bitstream.";
		}

		ogg_stream_init($os, ogg_page_serialno($og));
		vorbis_info_init($vi);
		vorbis_comment_init($vc);

		die "Error reading first page of Ogg bitstream data"
			if ogg_stream_pagein($os, $og) < 0;

		die "Error reading initial header packet."
			if ogg_stream_packetout($os, $op) != 1;

		die "Ogg bitstream does not contain Vorbis data"
			if vorbis_synthesis_headerin($vi, $vc, $op) < 0;

		my $i = 0;
		while ($i < 2) {
			while ($i < 2) {
				$result = ogg_sync_pageout($oy, $og);
				last if $result == 0;

				if ($result == 1) {
					ogg_stream_pagein($os, $og);

					while ($i < 2) {
						$result = ogg_stream_packetout($os, $op);
						last if $result == 0;
						die "Read corrupted secondary header from ogg packet"
							if $result < 0;

						die "Received corrupt secondary header from vorbis packet";

						$i++;
					}
				}
			}

			$!ogg_buffer = ogg_sync_buffer($oy, 4096);
			readInputBlock();

			die "Unexpected end of file while reading vorbis headers.";
				if $!bytes_io == 0 && $i < 2;
		}

		$!stream_info = (
			info => 	$vi,
			comments => $vc
		);

		.initialize_output if ! $!initialized;

		# cx: -YYY- Need to figure out what the eventual output is 
		#     supposed to look like and include vorbis_info and 
		#     vorbis_comment data.
		#
		#     Output should *not* need any knowledge of C structures.
		my @uc := nativecast(CArray[Str], $vc.user_comments);
		#loop (my $ci = 0; @uc[$ci].defined; $ci++) {
		#	diag "Comment: {@uc[$ci]}";
		#}

		$convsize = (4096 / $vi.channels).floor;
		my @outblocks;
		push @outblocks, Buf[int16].new(0 xx BLOCK_SIZE)
			for ^$vi.channels;

		# Start central decode.
		if (vorbis_synthesis_init($vd, $vi) == 0) {
			vorbis_block_init($vd, $vb);

			# Straight decode loop until end of stream 
			while ($eos != 0) {
		        while ($eos != 0) {
					$result = ogg_sync_pageout($oy, $og);

					# check if more data needed.
					last if $result == 0;

					die "Corrupt or missing data in bitstream" 
						if $result < 0;
						
					ogg_stream_pagein($os, $og);
		            loop {
						$result = ogg_stream_packetout($os, $op);
		              
		              	# check if more data needed.
		              	last if $result == 0;

						# check for unexpected error.
		              	die "Corrupt or missing data in bitstream."
							if $result < 0;

		                # We have a packet. Decode it.
		                my Pointer $pcm;
		                my $samples;

		                if (vorbis_synthesis($vb, $op) == 0) {
							vorbis_synthesis_blockin($vd, $vb);
		                }

		                $pcm .= new;
		                $samples = vorbis_synthesis_pcmout($vd, $pcm);
		                while ($samples > 0) {
		            		my ($j, $clipflag, $bout);
							$clipflag = 0;
							$bout = $samples < $convsize ?? $samples !! $convsize;

							my @channels := nativecast(CArray[CArray[num32]], $pcm);
							loop ($i = 0; $i < $vi.channels; $i++) {
								loop (my $j = 0; $j < $bout; $j++) {
									my ($val) = @channels[$i][$j] * 32767.5;

									if ($val > 32767) {
										$val = 32767;
										$clipflag = 1;
									} elsif ($val < -32768) {
								        $val = -32768;
								        $clipflag = 1;
								  	}

								  	@outblocks[$i][$j] = $val;
								}
							}
		                  
		                  	# cw: -YYY- May want to *not* emit this unless the 
		                  	#     user specifically asks for it.
							warn sprintf("Clipping in frame %ld", $vd.sequence)
								if $clipflag == 1;                  
		                  
		                  	# cw: -XXX- 
		                  	# Emit @outblocks either to disk or store to memory
		                  	#fwrite(convbuffer, 2 * vi.channels, bout, stdout);
		                  	#
		                  	# Keep channels separate, interleve or both? 
		                  	# Probably should be an option, which means
		                  	# the write routine will need to be more complex.
		                  	writeOutputBlocks(@outblocks);
		                  
		                  	vorbis_synthesis_read($vd, $bout);
	                  	}            
            		}

				    $eos = 1 if ogg_page_eos($og) != 0;
				}

				if ($eos == 0) {
					readInputBlock();
					$eos = 1 if $bytes == 0;
		      	}
			}

	      	# cw: This is worth keeping in mind -- 
		  	# 
			# * ogg_page and ogg_packet structs always point to storage in
		    # * libvorbis.  They're never freed or manipulated directly
			vorbis_block_clear($vb);
			vorbis_dsp_clear($vd);
		}

		ogg_stream_clear($os);
		vorbis_comment_clear($vc);
		vorbis_info_clear($vi);			# must be called last

	}
	ogg_sync_clear($oy);

	# cw: At the very least, let's return a hash. 
	my %return_val = {
		channels		=> $vi.channels,
		bitrate			=> $vi.bitrate,
		comments 		=> @uc,
		vendor			=> $vc.vendor,
		size			=> $!bytes_io
	}

	.finish_wav if %opts<output>:v eq 'wav'

	if $!input_data ~~ Blob {
		%return_val{output_streams} = $!output_data;
	}

	return %return_val;
}

# cw: Decode file on disk.
multi method decode(IO::Handle $fr, IO:Hanlde $fw, *%opts) {
	.actual_decode($fr, $fw, %opts);
}

# cw: Decode file on disk.
multi method decode(Str $fn, *%opts) {
	# check for existence or throw exception
	die "File $fn not found" unless $fn.IO.e;

	# By default output raw stream. 
	# Raw output in file mode will output one stream per file.
	# 	The default method for this method will output streams with the
	#	.raw extension followed by the channel number: .1, .2, etc
	# 
	# Use %opts to specify output as WAV (EXPERIMENTAL)
	# Due to the way the WAV file is structured, we need to write out the
	# converted data, first. Then we need to construct the header and 
	# prepend that to the output. So we first write to a wav.nh file 
	# (for "no header"). 
	my $ext =  %opts<output>:v eq 'wav' ?? 'wav.nh' !! 'raw.1';
	my $fno = $fn ~~ s/ '.' .+ $/.$ext/;

	# We open output file in rw mode, since we need to read what is sent output 
	# for proper WAV conversion.
	my $fhi = $fn.IO.open(:r, :bin);
	my $fho = open($fno, :rw, :bin);
	die "Can't open output file!" unless $fho;

	.decode($fhi, $fho, %opts);
}

# cw: Decode data in memory. Returns Buf.
multi method decode(Blob $b, *%opts) {
	# cw: Decoiding into memory so we create a new Buf object by default.
	#     .actual_decode will allocate more Buf objects depending on the
	#     number of channels, but we know we will -at least- need the one.
	.actual_decode($b, Buf[int16].new(), %opts);
}

# cw: Use this for appending files
sub sendfile (
	uint32 			!$out_fd, 
	uint32 			!$in_fd, 
	Pointer[uint32] !$offset, 
	uint32			!$count
) is native { * };

# cw: Do we -really- need instance variables of this class, or can these be static routines?
# cw: ALSO...current interface to decode() is incomplete. We need to handle options.
#     and said options should have reasonable defaults!
