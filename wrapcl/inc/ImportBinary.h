/*

AutoDock-GPU, an OpenCL implementation of AutoDock 4.2 running a Lamarckian Genetic Algorithm
Copyright (C) 2017 TU Darmstadt, Embedded Systems and Applications Group, Germany. All rights reserved.
For some of the code, Copyright (C) 2019 Computational Structural Biology Center, the Scripps Research Institute.

AutoDock is a Trade Mark of the Scripps Research Institute.

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

*/


#ifndef IMPORT_BINARY_H
#define IMPORT_BINARY_H

  //#include <stdio.h>
  //#include <stdlib.h>
  #include "commonMacros.h"
  #include "Programs.h"
  #include "Kernels.h"

/*

*/
  int load_file_to_memory(const char* filename,
                               char** result);

/*

*/
  int ImportBinary(const char*    kernel_xclbin,
                   const char*    kernel_name,
                   cl_device_id*  device_id,
                   cl_context     context,
                   /*cl_program*  program,*/
                   const char*    options,
                   cl_kernel*     kernel);

#endif /* IMPORT_BINARY_H */
