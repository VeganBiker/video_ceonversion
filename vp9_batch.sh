#!/bin/bash

# Check if a path is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <path-to-directory>"
    exit 1
fi

# Get the path to search from the command line
dir_to_search="$1"

number_of_threads=7

# Set the extensions to search for
extensions=(mp4 mov mpg m2t vob ts avi mkv m2v)

# Create a sub-directory for compressed files
mkdir -p "${dir_to_search}/compressed"

# Loop through each extension and find the files
for extension in "${extensions[@]}"; do
	# Find all files with the extension (case-insensitive)
	find "$dir_to_search" -iname "*.$extension" -type f -print0 |
	xargs -0 -I {} -P $number_of_threads bash -c '
		file="{}"
		filename="${file##*/}"
		filename_noext=${filename%.*}
		file_dir=${file%/*}
		compressed_dir="$file_dir/compressed"
		# Compress the file using ffmpeg
		compressed_file="${filename_noext}-vp9-opus.mkv"
		if [[ -f "$compressed_dir/$compressed_file" ]] || [[ "$filename" == *-vp9-opus.mkv ]]; then
            echo "${filename_noext} has already been processed. Skipping encoding."
		else
			# Check if the file is already VP9-encoded
			codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file")
			if [ "$codec" = "vp9" ]; then
				#echo "$file is already encoded in VP9. Skipping."
				echo ""
			else
				# Check if the video is interlaced
				output=$(ffmpeg -hide_banner -i "$file" -filter:v idet -frames:v 150 -an -f null /dev/null 2>&1)
				if [[ $(echo "$output" | grep -o "TFF: *[0-9]*" | awk "{print \$2}" | sed -n '1p') -gt 50 || $(echo "$output" | grep -o "BFF: *[0-9]*" | awk "{print \$2}" | sed -n '1p') -gt 50 ]]; then
					interlace=1
				else
					interlace=0
				fi
					# Set the encoding options based on whether the video is interlaced
				if [ $interlace == 1 ]; then
					# Add bwdif filter for deinterlacing
					frame_rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$file")
					fr_NUMERATOR=${frame_rate%/*}
					fr_DENOMINATOR=${frame_rate#*/}
					# Calculate the decimal frame rate using awk
					frame_rate_dec=$(awk "BEGIN {printf \"%.2f\", $fr_NUMERATOR/$fr_DENOMINATOR}")
					interlace_options="-vf bwdif,fps=$frame_rate_dec "
				else
					interlace_options=""
				fi
				encoding_options="-b:v 0 -crf 30 -threads 14 -tile-columns 2 -tile-rows 2 -frame-parallel 1 -row-mt 1 -keyint_min 48 -sc_threshold 0 $interlace_options -auto-alt-ref 1 -lag-in-frames 25"
					# Encode the video in two passes
				if [[ ! -e "${compressed_dir}/${filename_noext}-vp9-opus.passlog-0.log" ]]; then
					ffmpeg -hide_banner -y -i "$file" -c:v libvpx-vp9 -speed 4 $encoding_options -pass 1 -passlogfile "${compressed_dir}/${filename_noext}-vp9-opus.passlog" -an -f null /dev/null < /dev/null
				fi
				#dectect 5.1 side and remap
				sideaudio=$(ffprobe -i "$file" -show_streams -select_streams a:0 -loglevel quiet | grep channel_layout)
				if [ $sideaudio = "channel_layout=5.1(side)" ]; then
					audioremap="-af channelmap=channel_layout=5.1"
				fi
				ffmpeg -hide_banner -i "$file" -c:v libvpx-vp9 -speed 2 $encoding_options -pass 2 -passlogfile "${compressed_dir}/${filename_noext}-vp9-opus.passlog" -c:a libopus -b:a 160k $audioremap -c:s copy "${file%.*}-vp9-opus.mkv" < /dev/null
				# Move compressed file to a sub-directory of where they were found
				mkdir -p "$(dirname "$1")/compressed" &&
				if [[ $(stat -c%s "${file%.*}-vp9-opus.mkv") -eq 0  ]]; then
					echo "compression failed for $filename"
					rm -f "${file%.*}-vp9-opus.mkv"
				else
					mv "${file%.*}-vp9-opus.mkv" "$(dirname "$1")/compressed/"
					rm -f "${compressed_dir}/${filename_noext}-vp9-opus.passlog-0.log"
				fi
			fi
		fi
	'
done
