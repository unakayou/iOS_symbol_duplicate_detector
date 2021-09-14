#!/bin/bash
# 将当前目录下的dylib文件转化为符号

start_time=$(date +%s)

# 只导出符号
only_save_symbols=true

# 当前目录位置
project_path=$(cd `dirname $0`; pwd)

# 待提取dylib的真机缓存文件
dyld_shared_cache="./dyld_shared_cache_arm64"
echo "待提取的缓存文件: ${dyld_shared_cache}"

# 动态库输出文件夹
dylibDir="./dylib"
rm -rf ${dylibDir}
mkdir -p ${dylibDir}
echo "动态库输出位置: ${dylibDir}"

# 地址 + 类型 + 符号 保存位置
address_symbols_dir="./address_symbols"
if [[ ${only_save_symbols} == false ]]; then
	rm -rf ${address_symbols_dir}
	mkdir -p ${address_symbols_dir}
fi
echo "地址 类型 符号输出位置: ${address_symbols_dir}"

# 纯符号输出位置
symbols_only_dir="./only_symbols"
if [[ ${only_save_symbols} == true ]]; then
	rm -rf ${symbols_only_dir}
	mkdir -p ${symbols_only_dir}
fi
echo "纯符号输出位置: ${symbols_only_dir}"

# 动态库提取工具
extractor="./dsc_extractor"
echo "\033[33m正在提取 ${dyld_shared_cache} 中动态库...\033[0m"

# 使用 dsc_extractor 工具, 提取 dyld_shared_cache_arm64 中的动态库
${extractor} ${dyld_shared_cache} ${dylibDir}
echo "提取完毕, 开始解析动态库符号..."

# 递归遍历文件夹, 生成与动态库对应的符号文件
function dump_dir() {
	dirpath=$1
	echo "遍历 ${dirpath}"
	for file in ${dirpath}/*
	do
		# 如果 file 是个文件
		if test -f ${file} 
		then
			# 类型 1
			# 生成单个symbol文件, 以动态库命名
			#filePath="${address_symbols_dir}/${file##*/}.txt"
			#m -U ${file} > ${filePath}

			# 类型 2
			# 全部symbol导入一个文件中
			if [[ ${only_save_symbols} == false ]]; then
				# 2.1 写入符号地址 + 符号类型 + 符号名
				filePath="${address_symbols_dir}/dyld_symbols_all.txt"
				echo "\033[33m导出 ${file} 符号 -> ${filePath}\033[0m"
				echo "${file}" >> ${filePath} 
				nm -U -m -s __TEXT __text ${file} >> ${filePath}
				echo "" >> ${filePath}
			else
				# 2.2 只写入符号名
				filePath="${symbols_only_dir}/only_symbols.txt"
				echo "\033[33m导出 ${file} 符号 -> ${filePath}\033[0m"
				nm -U -j -s __TEXT __text ${file} >> ${filePath}
			fi
		else
			# 如果是文件夹 则递归
        	dump_dir ${file}
    	fi
	done
}

dump_dir ${dylibDir}

end_time=$(date +%s)
echo "执行完毕,耗时 `expr $end_time - $start_time` s."
