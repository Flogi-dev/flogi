# app/Comfort_commit/data/move_data.py

import os, psycopg2
from datetime import datetime

SOURCE_DB = os.getenv("MAIN_DB_URL")
TARGET_DB = os.getenv("DATA_DB_URL")

def move_code_embeddings(src, tgt):
    src.execute("""SELECT * FROM code_element_embeddings WHERE generated_at > NOW() - interval '7 days'""")
    for row in src.fetchall():
        tgt.execute("""INSERT INTO code_element_embeddings (...) VALUES (...) ON CONFLICT (...) DO UPDATE...""", row)

def move_llm_outputs(src, tgt):
    src.execute("""SELECT * FROM generated_technical_descriptions WHERE generated_at > NOW() - interval '7 days'""")
    for row in src.fetchall():
        tgt.execute("""INSERT INTO generated_technical_descriptions (...) VALUES (...) ON CONFLICT (...) DO UPDATE...""", row)

def run():
    s = psycopg2.connect(SOURCE_DB)
    d = psycopg2.connect(TARGET_DB)
    with s, d, s.cursor() as src, d.cursor() as tgt:
        move_code_embeddings(src, tgt)
        move_llm_outputs(src, tgt)
        # 추가 이동 로직 작성 예정
    print(f"✅ 이동 완료: {datetime.now()}")

if __name__ == "__main__":
    run()
