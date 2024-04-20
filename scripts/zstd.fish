function compress-dir
   # args are passed to zstd, you can specify --rm to remove source files
   # Example of usage:
   #    compress-dir -d ~/compression/a -c 22 -f -  # will write to stdout
   #    compress-dir -d ~/compression/a -c 22       # will create a.tar.zst file
   argparse --ignore-unknown "d/dir=" "f/file=" "c/compression=" "m/memory=" -- $argv || return
   if not set -q _flag_dir
      echo "Directory must be set"
      return
   end
   set parent_dir (dirname $_flag_dir)
   set base_dir (basename $_flag_dir)

   if not set -q _flag_compression
      set _flag_compression 19
   end
   if not set -q _flag_memory
      set _flag_memory 16384
   end
   if not set -q _flag_file
      set _flag_file $parent_dir/$base_dir.tar.zst
   end
   if test "$_flag_file" != "-" # - means stdout, in which case, file_arg_output should be empty
      set file_arg_output -f $_flag_file
   end

   echo "Compressing dir: $_flag_dir with compression: $_flag_compression, writing result to \"$file_arg_output\"" 1>&2

   tar -I "zstd --threads 0 --memory $_flag_memory --ultra -$_flag_compression $argv" -C $parent_dir -cv $file_arg_output $base_dir || return 1
   echo "Done" 1>&2
   ls -alh $parent_dir/$base_dir.tar.zst 1>&2
end
