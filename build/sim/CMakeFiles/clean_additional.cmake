# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "Release")
  file(REMOVE_RECURSE
  "C:\\GitHub\\PlayDateGame\\Excavator.pdx"
  "C:\\GitHub\\PlayDateGame\\Source\\pdex.dll"
  )
endif()
