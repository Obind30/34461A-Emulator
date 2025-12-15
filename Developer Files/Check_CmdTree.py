expect_fptr = open("Expected.txt", "r")
tree_fptr = open("Command_Tree.txt", "r")

expected = []
tree = []

line = expect_fptr.readline()
while line:
    expected.append(line)
    line = expect_fptr.readline()

line = tree_fptr.readline()
while line:
    tree.append(line)
    line = tree_fptr.readline()

expect_fptr.close()
tree_fptr.close()

print("SEARCHING TREE")
for i in tree:
    found = False
    for j in expected:
        if i == j:
            found = True
            break
    if found == False:
        print(i)
print("SEARCHING EXPECTED")
for i in expected:
    found = False
    for j in tree:
        if i == j:
            found = True
            break
    if found == False and i != "\n":
        print(i)
print("DONE")