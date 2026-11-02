import os,hashlib
from pathlib import Path
from datetime import datetime,date
import psycopg
from psycopg.types.json import Jsonb
from openpyxl import load_workbook

IMPORT_DIR=Path("/imports")

def clean(v):
	if v is None:return None
	if isinstance(v,(datetime,date)):return v.isoformat()
	if isinstance(v,(str,int,float,bool)):return v
	return str(v)

def sha256(p):
	h=hashlib.sha256()
	with p.open("rb") as f:
		for chunk in iter(lambda:f.read(1048576),b""):
			h.update(chunk)
	return h.hexdigest()

def main():
	files=[]
	for p in sorted(IMPORT_DIR.glob("*.xlsx")):
		if p.name.startswith("~$"):continue
		if "old" in p.stem.lower():
			print("SKIP OLD WORKBOOK:",p.name)
			continue
		files.append(p)
	if not files:raise SystemExit("No eligible XLSX files found in /imports")
	conn=psycopg.connect(host=os.environ["PGHOST"],port=os.getenv("PGPORT","5432"),dbname=os.environ["PGDATABASE"],user=os.environ["PGUSER"],password=os.environ["PGPASSWORD"])
	try:
		with conn.cursor() as cur:
			batch=datetime.now().strftime("excel_%Y%m%d_%H%M%S")
			cur.execute("INSERT INTO phase2_staging.import_batch (batch_name,status,notes) VALUES (%s,%s,%s) RETURNING id",(batch,"loading","Raw Excel staging import"))
			batch_id=cur.fetchone()[0]
			total=0
			for path in files:
				digest=sha256(path)
				cur.execute("SELECT id FROM phase2_staging.source_file WHERE filename=%s AND file_checksum=%s LIMIT 1",(path.name,digest))
				if cur.fetchone():
					print("SKIP ALREADY LOADED:",path.name)
					continue
				print("LOAD:",path.name)
				cur.execute("INSERT INTO phase2_staging.source_file (filename,file_checksum,notes) VALUES (%s,%s,%s) RETURNING id",(path.name,digest,"Imported from /imports"))
				file_id=cur.fetchone()[0]
				wb=load_workbook(path,data_only=False,keep_links=True)
				for ws in wb.worksheets:
					historical=any(x in ws.title.lower() for x in ["old","history","historical","archive"])
					rows=list(ws.iter_rows())
					if not rows:continue
					headers=[]
					for n,c in enumerate(rows[0],1):
						name=str(c.value).strip() if c.value is not None else "column_"+str(n)
						if name in headers:name=name+"_"+str(n)
						headers.append(name)
					cur.execute("INSERT INTO phase2_staging.source_sheet (source_file_id,sheet_name,historical_flag,row_count,notes) VALUES (%s,%s,%s,0,%s) RETURNING id",(file_id,ws.title,historical,"Raw Excel worksheet"))
					sheet_id=cur.fetchone()[0]
					staged=[]
					for rownum,row in enumerate(rows[1:],2):
						values={}
						has_data=False
						for header,cell in zip(headers,row):
							value=clean(cell.value)
							if value is not None:has_data=True
							values[header]=value
							if cell.hyperlink:values[header+"__hyperlink"]=cell.hyperlink.target
						if not has_data:continue
						raw={"_meta":{"workbook":path.name,"worksheet":ws.title,"excel_row_number":rownum,"historical_sheet":historical},"values":values}
						staged.append((sheet_id,batch_id,rownum,Jsonb(raw)))
					# One batched call per sheet instead of one round trip per row.
					if staged:
						cur.executemany("INSERT INTO phase2_staging.staging_row (source_sheet_id,import_batch_id,row_number,raw_json) VALUES (%s,%s,%s,%s)",staged)
					count=len(staged)
					total+=count
					cur.execute("UPDATE phase2_staging.source_sheet SET row_count=%s WHERE id=%s",(count,sheet_id))
					print("SHEET:",ws.title,"ROWS:",count,"HISTORICAL:",historical)
				wb.close()
			cur.execute("UPDATE phase2_staging.import_batch SET status=%s,notes=%s WHERE id=%s",("complete","Total staging rows: "+str(total),batch_id))
		conn.commit()
		print("IMPORT COMPLETE - TOTAL ROWS:",total)
	except Exception:
		conn.rollback()
		raise
	finally:
		conn.close()

if __name__=="__main__":
	main()
