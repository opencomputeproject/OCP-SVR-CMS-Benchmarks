#!/usr/bin/python3

f = open("results.txt","r");
lines = f.readlines();
f.close()

header = ""

wall = []
results = {
        "SET" : [],
        "GET" : [],
        "LPUSH" :  [],
        "LPUSH_LRANGE" : [],
        "LRANGE_100" : [],
        }

for line in lines:
    if not line:
        continue
    sline = line.split(",")
    if sline[0] == 'redis':
        wall.append(line)
    elif "test" in sline[0]:
        header = line
    elif "SET" in sline[0]:
        results["SET"].append(wall[-1].split(",")[1]+","+line)
    elif "GET" in sline[0]:
        results["GET"].append(wall[-1].split(",")[1]+","+line)
    elif "LPUSH" in sline[0]:
        results["LPUSH"].append(wall[-1].split(",")[1]+","+line)
    elif "benchmark" in sline[0]:
        results["LPUSH_LRANGE"].append(wall[-1].split(",")[1]+","+line)
    elif "LRANGE_100" in sline[0]:
        results["LRANGE_100"].append(wall[-1].split(",")[1]+","+line)

out = "program,settings,wall time\n"
header = "settings,"+header

for line in wall:
    out += line

for k in results:
    out += header
    for v in results[k]:
        out += v

f = open("results.csv", "w")
f.write(out)
f.flush()
f.close()

