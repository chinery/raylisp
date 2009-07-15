(in-package :raylisp)

(defclass box (scene-object)
  ((min :initform (vec -1.0 -1.0 -1.0) :initarg :min :reader min-of)
   (max :initform (vec 1.0 1.0 1.0) :initarg :max :reader max-of)))

(defun box-matrix (box)
  (let* ((co1 (min-of box))
         (co2 (max-of box))
         (min (vec-min co1 co2))
         (max (vec-max co1 co2)))
    (matrix* (translate (vec/ (vec+ max min) 2.0))
             (scale (vec/ (vec- max min) 2.0)))))

(defmethod compute-object-properties ((box box) scene matrix &key shading-object)
  (let* ((inverse (inverse-matrix (matrix* matrix (box-matrix box))))
         (adjunct (transpose-matrix inverse)))
    (list
     :intersection
     (unless shading-object
       (sb-int:named-lambda box-intersection (ray)
        (let ((o (transform-point (ray-origin ray) inverse))
              (d (transform-direction (ray-direction ray) inverse)))
          (declare (dynamic-extent o d))
          (with-arrays (d o)
            (let ((ox (o 0))
                  (oy (o 1))
                  (oz (o 2))
                  (dx (d 0))
                  (dy (d 1))
                  (dz (d 2)))
              (flet ((sides (oc dc)
                       (if (not (= dc 0.0))
                           (let ((t1 (/ (- -1.0 oc) dc))
                                 (t2 (/ (- 1.0 oc) dc)))
                             (if (> t1 t2)
                                 (values t2 t1)
                                 (values t1 t2)))
                           (values 0.0 float-positive-infinity))))
                (declare (inline sides))
                (let-values (((x1 x2) (sides ox dx))
                             ((y1 y2) (sides oy dy))
                             ((z1 z2) (sides oz dz)))
                  (let ((t1 (max x1 y1 z1))
                        (t2 (min x2 y2 z2))
                        (ext (ray-extent ray)))
                    (unless (> t1 t2)
                      (cond ((< epsilon t1 ext)
                             (setf (ray-extent ray) t1)
                             t)
                            ((< epsilon t2 ext)
                             (setf (ray-extent ray) t2)
                             t)))))))))))
     :normal
     (flet ((n (axis f)
              (let ((normal (vec 0.0 0.0 0.0)))
                (setf (aref normal axis) f)
                (normalize (transform-point normal adjunct)))))
       (let ((x (n 0 1.0))
             (-x (n 0 -1.0))
             (y (n 1 1.0))
             (-y (n 1 -1.0))
             (z (n 2 1.0))
             (-z (n 2 -1.0)))
        (lambda (point)
          (let ((p (transform-point point inverse)))
            (declare (dynamic-extent p))
            (let ((tmp 0.0))
              (cond ((=~ 1.0 (setf tmp (aref p 0)))  x)
                    ((=~ -1.0 tmp)                  -x)
                    ((=~ 1.0 (setf tmp (aref p 1)))  y)
                    ((=~ -1.0 tmp)                  -y)
                    ((=~ 1.0 (aref p 2))             z)
                    (t                              -z))))))))))

(defmethod compute-object-extents ((box box) transform)
  (transform-extents (vec -1.0 -1.0 -1.0)
                     (vec 1.0 1.0 1.0)
                     (matrix* transform (box-matrix box))))

(defmethod compute-csg-properties ((box box) scene matrix)
  (let ((inverse (inverse-matrix (matrix* matrix (box-matrix box))))
        (compiled (compile-scene-object box scene matrix :shading-object box)))
    (list
     :all-intersections
     (sb-int:named-lambda box-all-intersections (origin direction)
       (let ((o (transform-point origin inverse))
             (d (transform-direction direction inverse)))
         (declare (dynamic-extent o d))
         (with-arrays (d o)
           (let ((ox (o 0))
                 (oy (o 1))
                 (oz (o 2))
                 (dx (d 0))
                 (dy (d 1))
                 (dz (d 2)))
             (flet ((sides (oc dc)
                      (if (not (= dc 0.0))
                          (let ((t1 (/ (- -1.0 oc) dc))
                                (t2 (/ (- 1.0 oc) dc)))
                            (if (> t1 t2)
                                (values t2 t1)
                                (values t1 t2)))
                          (values 0.0 float-positive-infinity))))
               (declare (inline sides))
               (let-values (((x1 x2) (sides ox dx))
                            ((y1 y2) (sides oy dy))
                            ((z1 z2) (sides oz dz)))
                 (let ((t1 (max x1 y1 z1))
                       (t2 (min x2 y2 z2)))
                   (if (> t1 t2)
                       #()
                       (cond ((< epsilon t1)
                              (simple-vector (make-csg-intersection :distance t1 :object compiled)
                                             (make-csg-intersection :distance t2 :object compiled)))
                             ((< epsilon t2)
                              (simple-vector (make-csg-intersection :distance t2 :object compiled)))
                             (t
                              #()))))))))))
     :inside
     (lambda (point)
       (let ((p (transform-point point inverse)))
         (declare (dynamic-extent p))
         (and (<= -1.0 (aref p 0) 1.0)
              (<= -1.0 (aref p 1) 1.0)
              (<= -1.0 (aref p 2) 1.0)))))))