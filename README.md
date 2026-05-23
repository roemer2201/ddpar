# ddpar
Attempting scripted parallel dd execution.

## Usecases
### local
#### uncrompressed

| | clone (check) || backup (check) | restore (check) |
|----------|----------|-|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) || :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) || :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

#### compressed
| | backup gzip (check) | restore gzip (check) |
|-----------|----------|----------|
| block dev | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |
| file | :heavy_check_mark: (:heavy_check_mark:) | :heavy_check_mark: (:heavy_check_mark:) |

<br>

### remote - ssh
#### general remote funcionality (ssh)
| |state|
|-|-|
| establish_ssh_connection | :heavy_check_mark: |
| execute_command | :heavy_check_mark: |
| execute_remote_command | :heavy_check_mark: |
| execute_remote_background_command | :heavy_check_mark: |
| close_ssh_connection | :heavy_check_mark: |
| check_remote_command_availability | :stop_sign: |
| remote_port_generation | :heavy_check_mark: |
| check_remote_port_availability | :heavy_check_mark: |
| output_analysis | :heavy_check_mark: |
| remote_cloning_commands | :gear: |
| remote_backup_commands | :heavy_check_mark: |
| remote_restore_commands | :heavy_check_mark: |



<br>

### remote - netcat
#### uncompressed 
| | clone (check) | | backup (check) | restore (check) |
|-|----------|-|----------|----------|
| block dev | :heavy_check_mark: (:stop_sign:) | | :heavy_check_mark: (:stop_sign:) | :heavy_check_mark: (:stop_sign:) |
| file | :heavy_check_mark: (:stop_sign:) | | :heavy_check_mark: (:stop_sign:) | :heavy_check_mark: (:stop_sign:) |

#### local [de]compression
| | backup gzip (check) | restore gzip (check) |
|-|----------|----------|
| block dev | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
| file | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |

#### remote [de]compression
| | backup gzip (check) | restore gzip (check) |
|-----------|----------|----------|
| block dev | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
| file | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |

#### compressed transfer (compression+decompresion before and after transfer)
| | clone |
|----------|----------|
| block dev | :stop_sign: |
| file | :stop_sign: |

<br>
<!--
### remote - ???
#### uncompressed 
| | clone | | backup (check) | restore (check) |
|-|----------|-|----------|----------|
| block dev | :stop_sign: (:stop_sign:) | | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
| file | :stop_sign: (:stop_sign:) | | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
#### local [de]compression
| | backup gzip (check) | restore gzip (check) |
|-|----------|----------|
| block dev | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
| file | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
#### remote [de]compression
| | backup gzip (check) | restore gzip (check) |
|-----------|----------|----------|
| block dev | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
| file | :stop_sign: (:stop_sign:) | :stop_sign: (:stop_sign:) |
#### compressed transfer (compression+decompresion before and after transfer)
| | clone |
|----------|----------|
| block dev | :stop_sign: (:stop_sign:) |
| file | :stop_sign: (:stop_sign:) |
-->

## To Do
- check read/write permissions for $SOURCE, $BACKUP_BASE and $DESTINATION
- ddpar.sh:
  - Add option to give a backup a custom BASE_NAME
  - Add size check for local clone_file
  - Remove deprecated functions (currently none)
- ddpar-check.sh:
  - Add if-statement for checking if a backup as been created with a sha256sum
- ddpar-restore.sh:
  - check on file restore, if output is a file. If directory given, append basename from metadata
  - fallocate is run multiple times? (maybe only on restoring compressed block dev images?)
  - make fallocate optional
- use this BASE_NAME as path for checksum files for clones (where user request checksuming)
- echo a message if no reasonable alternative number of threads/jobs could be calculated
- when compressing an image and option -c (checksum) is given, should the script calculate the checksum of both, the raw file and the compressed file? (Currently only basefile's checksum is calculated.)
- Code to make missing features work
- Remoting:
  - Use differnt functions for remote actions like "output analysis" or implement in the existing functions?
  - Make remote input and local output work (not yet thought through)
