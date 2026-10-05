import json,sys
def rows(path):
    for l in open(path):
        i=l.find('RESULT {')
        if i>=0: yield json.loads(l[i+7:])
