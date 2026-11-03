# Discovery only: no reset, programming or target stop.
connect
puts "MEM_BOARD_TARGETS_BEGIN"
puts [targets]
puts "MEM_BOARD_TARGETS_END"
disconnect
exit
