import tempfile,sqlite3,unittest
from pathlib import Path
from health9_archive import Store,Collector

class Tests(unittest.TestCase):
 def test_restart_dedup_and_event(self):
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'a.sqlite3';s=Store(path)
   status={'session':'123'};history={'session':'123','next_after':1,'records':[{'cursor':1,'track':3}]};events={'session':'123','next_after':1,'events':[{'id':1,'revision':1,'closed':0}]}
   s.ingest(status,history,events);s.ingest(status,history,events)
   self.assertEqual(len(s.query()['records']),1);self.assertEqual(s.cursors('123'),(1,1));s.db.close()
   s=Store(path);self.assertEqual(len(s.query()['events']),1)
   events['events'][0].update(revision=2,closed=1);events['next_after']=2;s.ingest(status,history,events)
   self.assertEqual(s.query()['events'][0]['closed'],1)
   with self.assertRaises(ValueError):s.ingest({'session':'456'},history,events)
   s.db.close()
 def test_write_failure_isolated(self):
  class BadStore:
   def cursors(self,s):return 0,0
   def ingest(self,*args):raise sqlite3.OperationalError('disk full')
  c=Collector('http://mock',BadStore());responses=[{'session':'12'},{'session':'12','records':[]},{'session':'12','events':[]}]
  c.get=lambda path:responses.pop(0)
  with self.assertRaises(sqlite3.OperationalError):c.poll()

if __name__=='__main__':unittest.main()
