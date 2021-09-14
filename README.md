### 检测第三方库是否与系统动态库冲突

#### 简述

##### 一、系统库符号:

1. `dyld_shared_cache_xxx`:从 iPhone OS 3.1 开始，所有的系统库都打包成一个文件：dyld_shared_cache_xxx ，其中 xxx 表示具体的架构.

2. 获取`dyld_shared_cache_xxx`:

   - `https://www.theiphonewiki.com/wiki/Firmware_Keys/14.x` 网站可以下载对应的固件`.ipsw`, 蓝色代表可用.

   - 解压缩`ipsw`文件,得到三个`.dmg`文件. 打开占用空间最大的`.dmg`文件, 得到`/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64`备用.

3. 获取动态库导出器`dsc_extractor`:

   - ```c
     // 源码开源地址
     https://opensource.apple.com/source/dyld/
     
     // 压缩包下载地址
     https://opensource.apple.com/tarballs/dyld/
     ```

   - 下载最新`dyld`, 目前为`dyld-851.27.tar.gz`

   - 打开工程找到`dsc_extractor`

   - 将以下内容拷贝出来:

     ```c
     #include <stdio.h>
     #include <stddef.h>
     #include <dlfcn.h>
     
     
     typedef int (*extractor_proc)(const char* shared_cache_file_path, const char* extraction_root_path,
                                   void (^progress)(unsigned current, unsigned total));
     
     int main(int argc, const char* argv[])
     {
         if ( argc != 3 ) {
             fprintf(stderr, "usage: dsc_extractor <path-to-cache-file> <path-to-device-dir>\n");
             return 1;
         }
     
         //void* handle = dlopen("/Volumes/my/src/dyld/build/Debug/dsc_extractor.bundle", RTLD_LAZY);
         void* handle = dlopen("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/usr/lib/dsc_extractor.bundle", RTLD_LAZY);
         if ( handle == NULL ) {
             fprintf(stderr, "dsc_extractor.bundle could not be loaded\n");
             return 1;
         }
     
         extractor_proc proc = (extractor_proc)dlsym(handle, "dyld_shared_cache_extract_dylibs_progress");
         if ( proc == NULL ) {
             fprintf(stderr, "dsc_extractor.bundle did not have dyld_shared_cache_extract_dylibs_progress symbol\n");
             return 1;
         }
     
         int result = (*proc)(argv[1], argv[2], ^(unsigned c, unsigned total) { printf("%d/%d\n", c, total); } );
         fprintf(stderr, "dyld_shared_cache_extract_dylibs_progress() => %d\n", result);
         return 0;
     }
     ```

   - 执行命令, 创建可执行文件`dsc_extractor` :

     ```shell
     clang++ -o dsc_extractor dsc_extractor.cpp
     ```

4. 使用`dsc_extractor`导出系统动态库到`dylib`文件夹:

   - ```shell
     ./dsc_extractor dyld_shared_cache_arm64 dylib
     ```

   

5. 导出系统库符号(目前iOS 14.6系统符号`T(__Text __text)`类型大概有370万):

   ```shell
   # 检测冲突符号时使用
   # -j: 只导出符号名.
   nm -U -j -s __TEXT __text ${file} >> ${filePath}
   
   # 检测到冲突后,到此文件中查看对应符号的详细信息.
   # -U: 只导出已定义符号, -m: 显示详细符号类型, -s: 只导出__TEXT __text段(T/t)符号.
   nm -U -m -s __TEXT __text ${file} >> ${filePath}
   ```

##### 二、第三方库符号

1. 导出三方库符号

   ```shell
   # 检测冲突符号时使用.
   # -U: 只导出已定义符号, -s: 只导出T/t符号.
   nm -U -s __TEXT __text ${file_library_path} > ${symbol_path}
   ```

2. 处理三方库符号: 逐行读取`三方库符号.txt`文件, 以`空格`切每一行, 取倒数第一个或倒数第二项, 组成符号名称.

3. 使用如下命令去`dylib_get_symbols/only_symbols/only_symbols.txt`匹配是否有重复符号.

   ```shell
   # -m 1: 找到一个就立刻返回, --: 标记后面的为需要匹配的字符串,防止匹配-[Class function]时导致解析错误.
   fgrep  -m 1 -- "${line_symbol}" ${dylib_symbol_path}
   ```

#### 测试

- 经测试.对于系统符号数据量:370万, 使用`fgrep`效率最高.最低0s, 最高4s, 平均2s,  与此符号在系统符号库中的位置有关.

- 多进程方式 (目前采用第一种) : 

  1. N个进程读同一个三方符号表, 各取不同符号, 然后去同一个系统符号表中对比. ✅

  2. 将三方库符号表拆分成N份文件, 每个进程负责遍历一份拆分出来的三方库子符号表.

- 测试`CrashSDK.framework`,数据量: 920 x 370万, 环境: 6 Physical, 12 Hyper-Threading核心 CPU:

  - 1进程, CPU占用10%-15%, 时间2490s

  - 6进程(物理CPU数),  CPU占用52%-55%, 时间 512 s

  - 10进程, CPU占用85%-90%, 时间497s.
  - 12进程(逻辑CPU数), CPU占用100%, 时间502s.
  - 100进程, CPU占用100%, 时间455s.
  - 最终取物理CPU数量作为进程数.大量进程同时检测, 可能会频繁挂起, 导致速度未有明显提升, 反而计算机卡顿发热严重.

- 检测结果为(大写`T`为全局符号, 小写`t`为局部符号): 

  ```tex
  ./symbols/CrashSDK.txt重复符号:
  0000000000000080 T ___clang_call_terminate
  00000000000006e8 t __ZNSt12length_errorC1EPKc
  0000000000000584 t __ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEC1IDnEEPKc
  0000000000000606 T __ZNSt3__16vectorItNS_9allocatorItEEE26__swap_out_circular_bufferERNS_14__split_bufferItRS2_EEPt
  00000000000002f0 T __ZNSt3__16vectorItNS_9allocatorItEEE6resizeEm
  0000000000000712 T __ZNSt3__16vectorItNS_9allocatorItEEE8__appendEm
  0000000000000100 T ___clang_call_terminate
  0000000000000620 T ___clang_call_terminate
  0000000000000220 T ___clang_call_terminate
  0000000000000c89 T ___copy_helper_block_ea8_32b40s
  0000000000000b6d T ___copy_helper_block_ea8_32s
  0000000000000698 T ___copy_helper_block_ea8_32s40b
  000000000000059d T ___copy_helper_block_ea8_32s40b48s
  0000000000000b7c T ___destroy_helper_block_ea8_32s
  00000000000006c8 T ___destroy_helper_block_ea8_32s40s
  00000000000005e3 T ___destroy_helper_block_ea8_32s40s48s
  000000000000168e T ___copy_helper_block_ea8_32s40s48b
  00000000000009ee T ___copy_helper_block_ea8_32s40s48s
  00000000000000cc T ___copy_helper_block_e8_
  0000000000001d55 T ___copy_helper_block_e8_32b40s
  00000000000005e6 T ___copy_helper_block_e8_32s
  0000000000000a19 T ___copy_helper_block_e8_32s40s
  00000000000000d2 T ___destroy_helper_block_e8_
  00000000000005f5 T ___destroy_helper_block_e8_32s
  0000000000000a3e T ___destroy_helper_block_e8_32s40s
  0000000000000d90 T ___clang_call_terminate
  0000000000001bfb T ___copy_helper_block_ea8_32s
  0000000000001c0a T ___destroy_helper_block_ea8_32s
  000000000000019d t _ReachabilityCallback
  00000000000005da t __ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEC1IDnEEPKc
  0000000000000edc t __ZNSt12length_errorC1EPKc
  000000000000129a T __ZNSt3__16vectorIhNS_9allocatorIhEEE11__vallocateEm
  0000000000000d88 T __ZNSt3__16vectorIhNS_9allocatorIhEEE8__appendEm
  0000000000001226 T __ZNSt3__16vectorIhNS_9allocatorIhEEEC2IPhEET_NS_9enable_ifIXaasr27__is_cpp17_forward_iteratorIS6_EE5valuesr16is_constructibleIhNS_15iterator_traitsIS6_E9referenceEEE5valueES6_E4typeE
  0000000000000dd8 t ___Block_byref_object_copy_
  0000000000000dee t ___Block_byref_object_dispose_
  0000000000000f3a T ___copy_helper_block_e8_32s40r48r
  000000000000176d T ___copy_helper_block_e8_32s40r48r56r
  0000000000000f7c T ___destroy_helper_block_e8_32s40r48r
  00000000000017c1 T ___destroy_helper_block_e8_32s40r48r56r
  00000000000000a0 T ___clang_call_terminate
  00000000000003c0 T ___clang_call_terminate
  00000000000027e0 T ___clang_call_terminate
  00000000000035ba T ___copy_helper_block_e8_32b
  00000000000035d1 T ___destroy_helper_block_e8_32s
  0000000000001d12 t ___Block_byref_object_copy_
  0000000000001d28 t ___Block_byref_object_dispose_
  0000000000001e3f T ___copy_helper_block_e8_40s48r56r
  0000000000001e81 T ___destroy_helper_block_e8_40s48r56r
  ```
  

#### 脚本逻辑

1. 导出系统动态库`dyld_shared_cache_arm64`所有符号,写入文件内`dylib_get_symbols/only_symbols/only_symbols.txt`.
2. 导出所有待检测的三方库符号,写入以三方库命名的文件内`library_get_symbols/symbols/xxxframework.txt`.每个三方库生成一个符号文件.
3. 按序遍历每一个三方库生成的符号文件,并且去`dylib_get_symbols/only_symbols/only_symbols.txt`中查找是否重复.如果重复,写入`library_get_symbols/dumplicate_symbols`中.

#### 脚本使用说明

1. 打开`dylib_get_symbols`目录, 将下载好的系统库`dyld_shared_cache_arm64`拷贝到当前目录, 执行脚本`dylib_extractor.sh`.
2. 打开`library_get_symbols`目录, 将需要检测的三方库拷贝到当前目录, 执行脚本`library_extractor.sh`.
3. 打开`library_get_symbols/dumplicate_symbols/dumplicate_symbols.txt`,查看重复符号.