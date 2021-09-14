#!/bin/bash
# 将当前文件夹下的动、静态库提取符号,与所有系统库符号进行查重

start_time=$(date +%s)

# 系统动态库符号表
dylib_symbol_path="$(dirname "$PWD")/dylib_get_symbols/only_symbols/only_symbols.txt"
# dylib_symbol_path="$(dirname "$PWD")/dylib_get_symbols/address_symbols/dyld_symbols_all.txt"
echo "系统符号路径 ${dylib_symbol_path}"
if [ ! -f "$dylib_symbol_path" ]; then
echo "\033[31mError: 系统符号表不存在\033[0m"
exit
fi

# 符号输出位置
symbols_dir="./symbols"
rm -rf ${symbols_dir}
mkdir -p ${symbols_dir}
echo "library 符号输出位置: ${symbols_dir}"

# 重复符号输出位置
duplicate_symbol_dir="./dumplicate_symbols"
rm -rf ${duplicate_symbol_dir}
mkdir -p ${duplicate_symbol_dir}
echo "重复符号输出位置: ${duplicate_symbol_dir}"

# 设置并发的进程数
# cup_info=($(sysctl hw.logicalcpu))	# 逻辑CPU数量
cup_info=($(sysctl hw.physicalcpu))	# 物理CPU数量
cup_num=${cup_info[${#cup_info[*]}-1]}
echo "CPU核心数量: ${cup_num}"

thread_num=${cup_num}
echo "开启进程数量: ${thread_num}"

# 最大写文件数
write_num=1

# 获取当前目录下所有静态库文件的符号
echo "开始解析当前目录下 library 为符号文件"

for file in *
do
	# 取文件后缀
	suffix="${file##*.}"

	# 待写入 library
	file_library_path=""

	# 写入符号位置
	symbol_path="${symbols_dir}/${file%.*}.txt"

	if [[ ${suffix} == "framework" ]]; then
		# framework 需要取 xxx.framework/xxx
		file_library_path=${file}/${file%.*}
	elif [[ ${suffix} == "a" ]]; then
		# .a 直接导出符号
		file_library_path=${file}
	else 
		# 其他类型不导出
		continue
	fi
		# 导出符号
		echo "\033[33m导出 ${file_library_path} 符号 -> ${symbol_path}\033[0m"
		nm -U -s __TEXT __text ${file_library_path} > ${symbol_path}
done

echo "所有 library 已经转化为符号"

####################################################

# 并发
# 创建管道1, 控制并发数
concurrentfifo="concurrent_fifo"
mkfifo ${concurrentfifo}

# 用文件句柄 打开管道文件
exec 6<>${concurrentfifo}
rm -f ${concurrentfifo}

# 控制并发数
for i in `seq $thread_num`
do
# 向管道中放入 thread_num 个令牌, 等待 read
	echo >&6
done

####################################################

# 文件读写进程锁
mutexfifo="mutex_fifo"
mkfifo ${mutexfifo}

# 打开管道
exec 8<>${mutexfifo}
rm -f ${mutexfifo}

# 放入一个令牌
echo >&8

####################################################

echo "开始检测冲突符号, 写入${duplicate_symbol_dir}/dumplicate_symbols.txt"

# 遍历每一个 library_symbol_file
for library_symbol_file in ${symbols_dir}/*
do
{
	echo "\033[33m逐行读取 ${library_symbol_file} 符号\033[0m"

	# 尝试拿写锁
	read -u 8
	{
		echo "${library_symbol_file}重复符号:" >> ${duplicate_symbol_dir}/dumplicate_symbols.txt
		# 交还令牌
		echo >&8
	}

	# 遍历系统符号每一行
	cat ${library_symbol_file} | while read line
	do
	{	
		# 通过文件句柄读取行，当行取尽时，停止下一步（并发）
		read -u 6
		{
			# 每一行符号按照空格切割为数组
    		line_arry=($line)

    		# 路径不判断
    		if [[ ${#line_arry[@]} == 1 ]]; then
    			# 返回时必须交还令牌,否则导致令牌最终减为0,进程死锁
    			echo >&6
    			continue
    		fi

    		# 空行不判断
			if [[ ${#line} == 0 ]]; then
				echo >&6
    			continue
    		fi

    		# OC 符号取后两位, C、C++ 取最后一位. 
    		# 第一位:符号虚拟地址 第二位: 符号类型 第三位: 符号名称 第四位: OC符号名称
			third="${line_arry[2]}"
			fourth="${line_arry[3]}"

			# fourth 非空, 则为OC符号
			if [ -n "$fourth" ]; then
				line_symbol="${third} ${fourth}"
			else
				line_symbol="${third}"
			fi

			echo "\033[33m正在对比 ${line_symbol}\033[0m"

			# 在 dylib_symbol_path 中查找是否包含 line_symbol,找到一个直接记录
			ret=$(fgrep -w -m 1 -- "${line_symbol}" ${dylib_symbol_path})
			if [ ! "${ret}" ]; then
				echo "未包含 ${line_symbol}"
			else
				echo "\033[31m发现重复符号! ${line_symbol}\033[0m"

				# 尝试拿写锁
				read -u 8
				{
					echo "${line}" >> ${duplicate_symbol_dir}/dumplicate_symbols.txt
					# 交还令牌
					echo >&8
				}
			fi

			# 一个并发执行后要想管道中在加入一个空行，供下次使用
			echo >&6
		} &
	} 
	done

	read -u 8
	{
		# 写一个换行进去
		echo >> ${duplicate_symbol_dir}/dumplicate_symbols.txt
		echo >&8
	}
}
done

# 等待子进程结束,再继续下面代码
wait

# 关闭管道
exec 6>&-
exec 8>&-

end_time=$(date +%s)
echo "执行完毕,耗时 `expr $end_time - $start_time` s."
