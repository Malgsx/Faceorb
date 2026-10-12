# Usage: python3 embed_reference.py <album-dir> <models-dir with yunet.onnx + sface.onnx> <out faces.json>
# Python twin of the app pipeline. YuNet stands in for Apple Vision (not available off-Mac);
# alignment, preprocessing and SFace are identical to FaceOrbCore/FaceOrbKit.
# Reference pipeline: YuNet (stand-in for Apple Vision) -> 5-pt similarity align -> SFace via ORT.
import sys, json, numpy as np, cv2, onnxruntime as ort
from pathlib import Path
ort.set_default_logger_severity(3)
album, models, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
DST = np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],[41.5493,92.3655],[70.7299,92.2041]])
def umeyama(src, dst):
    mu_s, mu_d = src.mean(0), dst.mean(0); s0, d0 = src-mu_s, dst-mu_d
    var = (s0**2).sum()/len(src)
    # closed form 2D similarity: a = sum(s.d)/sum|s|^2, b = sum(s x d)/sum|s|^2
    n = (s0**2).sum()
    a = (s0[:,0]*d0[:,0] + s0[:,1]*d0[:,1]).sum()/n
    b = (s0[:,0]*d0[:,1] - s0[:,1]*d0[:,0]).sum()/n
    M = np.array([[a,-b,0],[b,a,0]],float)
    M[:,2] = mu_d - M[:,:2]@mu_s
    return M
def warp(img, M):  # bilinear inverse map, mirrors Swift implementation
    A = np.vstack([M,[0,0,1]]); inv = np.linalg.inv(A)
    ys, xs = np.mgrid[0:112,0:112]
    sx = inv[0,0]*xs+inv[0,1]*ys+inv[0,2]; sy = inv[1,0]*xs+inv[1,1]*ys+inv[1,2]
    x0 = np.floor(sx).astype(int); y0 = np.floor(sy).astype(int); fx = sx-x0; fy = sy-y0
    H,W = img.shape[:2]
    def px(x,y):
        ok = (x>=0)&(x<W)&(y>=0)&(y<H)
        v = img[np.clip(y,0,H-1), np.clip(x,0,W-1)].astype(np.float32); v[~ok]=0; return v
    f = lambda a: a[...,None]
    return (px(x0,y0)*f((1-fx)*(1-fy)) + px(x0+1,y0)*f(fx*(1-fy)) + px(x0,y0+1)*f((1-fx)*fy) + px(x0+1,y0+1)*f(fx*fy))
det = cv2.FaceDetectorYN.create(str(models/"yunet.onnx"), "", (320,320), 0.8)
rec = cv2.FaceRecognizerSF.create(str(models/"sface.onnx"), "")
sess = ort.InferenceSession(str(models/"sface.onnx"))
faces=[]; checks=[]
for p in sorted(album.glob("*.jpg")):
    bgr = cv2.imread(str(p)); H,W = bgr.shape[:2]; det.setInputSize((W,H))
    _, dets = det.detect(bgr)
    if dets is None: continue
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    for d in dets:
        lm = d[4:14].reshape(5,2).astype(float)
        if d[2] < 40: continue  # tiny faces
        M = umeyama(lm, DST); crop = warp(rgb, M)
        x = crop.transpose(2,0,1)[None].astype(np.float32)
        e = sess.run(None, {"data": x})[0][0]; e = e/np.linalg.norm(e)
        if len(checks) < 20:
            ref = rec.feature(rec.alignCrop(bgr, d))[0]; ref = ref/np.linalg.norm(ref); checks.append(float(e@ref))
        faces.append({"photo": p.stem, "box": [float(v) for v in d[:4]], "landmarks": lm.tolist(), "embedding": [round(float(v),5) for v in e]})
print("faces", len(faces), "photos", len({f['photo'] for f in faces}))
print("cos(ours, cv2 FaceRecognizerSF) min/mean:", min(checks), sum(checks)/len(checks))
json.dump(faces, open(out,"w"))
