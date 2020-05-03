<h2>Murphi MSI/MESI Cache Coherence</h2>
<p>These cache coherence protocols were designed from scratch and implemented in Murphi for EECS 570. Correctness was verified for up to three sharers on a single cache block, and the implementation assumes an unordered network.</p>

<p><i><b>Disclaimer:</b> Functionality and simplicity were my only goals for the project (since we weren't graded on performance), and so my design will be horribly inefficient in practice and has more virtual channels and transient states than necessary. </i></p>

<p>The designs for MSI and MESI are shown below, with red states highlighting differences from the (ordered network) baseline described in Sorin et al's "A Primer on Memory Consistency and Cache Coherence".</p>

<b>MSI:</b>
<div style='text-align:center'>
<img src='https://github.com/TimD1/CacheCoherence/blob/master/img/msi_proc.png'></img>
<img src='https://github.com/TimD1/CacheCoherence/blob/master/img/msi_dir.png'></img>
</div>
<b>MESI:</b>
<div style='text-align:center'>
<img src='https://github.com/TimD1/CacheCoherence/blob/master/img/mesi_proc.png'></img>
<img src='https://github.com/TimD1/CacheCoherence/blob/master/img/mesi_dir.png'></img>
</div>
