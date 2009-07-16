(in-package :raylisp)

(declaim (optimize (debug 2)))

(deftype axis ()
  '(member 0 1 2))

(declaim (inline next-axis prev-axis))
(defun next-axis (axis)
  (declare (axis axis))
  (if (= axis 2)
      0
      (1+ axis)))

(defun prev-axis (axis)
  (declare (axis axis))
  (if (= axis 0)
      2
      (1- axis)))

(defstruct (kd-node  (:constructor nil))
  (min (required-argument) :type vec)
  (max (required-argument) :type vec))

(declaim (inline kd-min kd-max))

(defun kd-min (kd-node)
  (kd-node-min kd-node))
(defun kd-max (kd-node)
  (kd-node-max kd-node))

(defstruct (kd-interior-node (:include kd-node))
  (left (required-argument :left) :type kd-node)
  (right (required-argument :right) :type kd-node)
  (axis (required-argument :axis) :type axis)
  (plane-position (required-argument :plane-position) :type single-float))

(declaim (inline kd-left kd-right kd-axis kd-plane-position kd-depth))

(defun kd-left (kd-node)
  (kd-interior-node-left kd-node))

(defun kd-right (kd-node)
  (kd-interior-node-right kd-node))

(defun kd-axis (kd-node)
  (kd-interior-node-axis kd-node))

(defun kd-plane-position (kd-node)
  (kd-interior-node-plane-position kd-node))

(defun kd-depth (kd-node)
  (labels ((rec (node)
             (if (kd-interior-node-p node)
                 (1+ (max (rec (kd-interior-node-left node))
                          (rec (kd-interior-node-right node))))
                 1)))
    (rec kd-node)))

(defstruct (kd-leaf-node (:include kd-node) (:predicate kd-leaf-p))
  objects)

(declaim (inline kd-objects))

(defun kd-objects (kd-node)
  (kd-leaf-node-objects kd-node))

(defconstant +kd-stack-node-index+     0)
(defconstant +kd-stack-distance-index+ 1)
(defconstant +kd-stack-point-index+    2)
(defconstant +kd-stack-prev-index+     3)
(defconstant +kd-stack-entry-size+     4)

(declaim (inline make-kd-stack
                    kd-stack-node kd-stack-distance kd-stack-point kd-stack-prev
                    (setf kd-stack-node) (setf kd-stack-distance)
                    (setf kd-stack-point) (setf kd-stack-prev)))

(defun make-kd-stack (kd-node)
  (make-array (* +kd-stack-entry-size+ 50)))

(defun kd-stack-node (stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-node-index+)))

(defun (setf kd-stack-node) (node stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (setf (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-node-index+)) node))

(defun kd-stack-distance (stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-distance-index+)))

(defun (setf kd-stack-distance) (distance stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (setf (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-distance-index+)) distance))

(defun kd-stack-point (stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-point-index+)))

(defun (setf kd-stack-point) (point stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (setf (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-point-index+)) point))

(defun kd-stack-prev (stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-prev-index+)))

(defun (setf kd-stack-prev) (prev stack pointer)
  (declare (simple-vector stack) (fixnum pointer))
  (setf (aref stack (+ (* pointer +kd-stack-entry-size+) +kd-stack-prev-index+)) prev))

(defun find-intersection-in-kd-tree (ray root counters shadowp)
  (flet ((kd-intersect (objects min max)
           (%find-intersection ray objects min max counters shadowp)))
    (kd-traverse #'kd-intersect ray root)))

;;; RayTravAlgRECB from Appendix C.
(defun kd-traverse (function ray root)
  (declare (kd-node root)
           (function function)
           (ray ray)
           (optimize speed))
  (multiple-value-bind (entry-distance exit-distance)
      (ray/box-intersections ray (kd-min root) (kd-max root))
    (declare (type (or null float) entry-distance)
             (float exit-distance))
    (when entry-distance
      (unless (kd-interior-node-p root)
        (let ((objects (kd-objects root)))
          (return-from kd-traverse
            (when objects (funcall function objects nil nil)))))
      (let ((stack (make-kd-stack root))
            (current-node root)
            (entry-pointer 0)
            (ray-origin (ray-origin ray))
            (ray-direction (ray-direction ray)))
        (declare (dynamic-extent stack))
        (setf (kd-stack-distance stack entry-pointer) entry-distance
              (kd-stack-point stack entry-pointer)
              (if (>= entry-distance 0.0)
                  (adjust-vec ray-origin ray-direction entry-distance)
                  ray-origin))
        (let ((exit-pointer 1)
              (far-child nil))
          (declare (fixnum exit-pointer))
          (setf (kd-stack-distance stack exit-pointer) exit-distance)
          (setf (kd-stack-point stack exit-pointer)
                (adjust-vec ray-origin ray-direction exit-distance))
          (setf (kd-stack-node stack exit-pointer) nil)
          (loop while current-node
                do (loop until (kd-leaf-p current-node)
                         do (tagbody
                               (let* ((split (kd-plane-position current-node))
                                      (axis (kd-axis current-node))
                                      (entry-projection
                                       (aref (the vec (kd-stack-point stack entry-pointer)) axis))
                                      (exit-projection
                                       (aref (the vec (kd-stack-point stack  exit-pointer)) axis)))
                                 (cond ((<= entry-projection split)
                                        (cond ((<= exit-projection split)
                                               (setf current-node (kd-left current-node))
                                               (go :cont))
                                              ((= exit-projection split)
                                               (setf current-node (kd-right current-node))
                                               (go :cont))
                                              (t
                                               (setf far-child (kd-right current-node)
                                                     current-node (kd-left current-node)))))
                                       ((< split exit-projection)
                                        (setf current-node (kd-right current-node))
                                        (go :cont))
                                       (t
                                        (setf far-child (kd-left current-node)
                                              current-node (kd-right current-node))))
                                 (let ((distance (/ (- split (aref ray-origin axis)) (aref ray-direction axis)))
                                       (tmp exit-pointer))
                                   (incf-fixnum exit-pointer)
                                   (when (= exit-pointer entry-pointer)
                                     (incf-fixnum exit-pointer))
                                   ;; FIXME: seem better to either use explicit recursion, or
                                   ;; at least split the stack into several: one stack per object
                                   ;; type, so we don't need to cons up vectors to store there...
                                   (setf (kd-stack-prev stack exit-pointer) tmp
                                         (kd-stack-distance stack exit-pointer) distance
                                         (kd-stack-node stack exit-pointer) far-child
                                         (kd-stack-point stack exit-pointer)
                                         (let ((point (make-array 3 :element-type 'float))
                                               (next-axis (next-axis axis))
                                               (prev-axis (prev-axis axis)))
                                           (setf (aref point axis) split)
                                           (setf (aref point next-axis)
                                                 (+ (aref ray-origin next-axis)
                                                    (* distance (aref ray-direction next-axis))))
                                           (setf (aref point prev-axis)
                                                 (+ (aref ray-origin prev-axis)
                                                    (* distance (aref ray-direction prev-axis))))
                                           point))))
                             :cont))
                (when current-node
                  (let ((objects (kd-objects current-node)))
                    (when objects
                      (multiple-value-bind (result info)
                          (funcall function objects
                                   (kd-stack-distance stack entry-pointer)
                                   (kd-stack-distance stack exit-pointer))
                        (when result
                          (return-from kd-traverse (values result info)))))))
                (setf entry-pointer exit-pointer
                      current-node (kd-stack-node stack exit-pointer)
                      exit-pointer (kd-stack-prev stack entry-pointer))))))))

(defun ray/box-intersections (ray bmin bmax)
  (declare (type vec bmin bmax)
           (optimize speed))
  (let ((dir (ray-direction ray))
        (orig (ray-origin ray)))
    (with-arrays (dir orig)
     (let ((ox (orig 0))
           (oy (orig 1))
           (oz (orig 2))
           (dx (dir 0))
           (dy (dir 1))
           (dz (dir 2)))
       (flet ((sides (axis oc dc)
                (if (not (= dc 0.0))
                    (let ((t1 (/ (- (aref bmin axis) oc) dc))
                          (t2 (/ (- (aref bmax axis) oc) dc)))
                      (if (> t1 t2)
                          (values t2 t1)
                          (values t1 t2)))
		    (values 0.0 float-positive-infinity))))
         (declare (inline sides))
         (let-values (((x1 x2) (sides 0 ox dx))
                      ((y1 y2) (sides 1 oy dy))
                      ((z1 z2) (sides 2 oz dz)))
           (let ((t1 (max x1 y1 z1))
                 (t2 (min x2 y2 z2)))
             (if (> t1 t2)
                 (values nil 0.0)
                 (values t1 t2)))))))))

;;;; KD TREE BUILDING in O(N log N)
;;;;
;;;; From "On building fast kd-Trees for Ray Tracing, and on doing that in O(N
;;;; log N)" by Ingo Wald and Vlastimil Havran, 2006
;;;;
;;;; See: papers/ingo06rtKdtree.pdf
;;;;
;;;; This is essentially what the paper says, except we don't do perfect splits.
;;;;
;;;; The interface is somewhat generic: define appropriate methods on
;;;;
;;;;   KD-SET-SIZE set
;;;;   MAP-KD-SET function set
;;;;   MAKE-KD-SUBSET subset set
;;;;   KD-OBJECT-MIN object set
;;;;   KD-OBJECT-MAX object set
;;;;
;;;; and you can hand your own data to the implemntation and cast rays at it
;;;; using KD-TRAVERSE. See Eg. objects/mesh.lisp for what this is good for.
;;;;
;;;; Ideally you should always dispatch on SET -- and the two first ones you
;;;; really have no option.

(defgeneric kd-set-size (set))
(defgeneric map-kd-set (function set))
(defgeneric make-kd-subset (subset set))
(defgeneric kd-object-min (object set))
(defgeneric kd-object-max (object set))

(defstruct event
  (object (required-argument :object))
  (type (required-argument :type) :type (integer 0 2))
  (id (required-argument :id) :type (and unsigned-byte fixnum))
  (e (required-argument :e) :type single-float)
  (k (required-argument :k) :type (integer 0 2)))

;;; Start, parellel, and end events.
(defconstant .e+ 0)
(defconstant .e! 1)
(defconstant .e- 2)

(defun event< (a b)
  (let ((ae (event-e a))
        (be (event-e b)))
    (or (< ae be)
        (and (= ae be)
             (< (event-type a) (event-type b))))))

(defun events->subset (events set)
  (declare (simple-vector events))
  (let (objects)
    (dotimes (i (length events))
      (let ((obj (event-object (aref events i))))
        (push obj objects)))
    (make-kd-subset (delete-duplicates objects) set)))

(defparameter *kd-traversal-cost* 0.2)
(defparameter *intersection-cost* 0.05)

(defun build-kd-tree (set min max)
  (let ((size (kd-set-size set)))
    (labels ((rec (n events min max)
               (multiple-value-bind (e k side cost) (find-plane n events min max)
                 (if (> cost (* *intersection-cost* n))
                     (make-kd-leaf-node :min min :max max
                                        :objects (when (plusp (length events))
                                                   (events->subset events set)))
                     (multiple-value-bind (left-events right-events nl nr)
                         (split-events size events e k side)
                       (multiple-value-bind (lmin lmax rmin rmax) (split-voxel min max e k)
                         (values (make-kd-interior-node
                                  :plane-position e
                                  :axis k
                                  :min min
                                  :max max
                                  :left (rec nl left-events lmin lmax)
                                  :right (rec nr right-events rmin rmax)))))))))
      (rec size (build-events size set) min max))))

(defun build-events (size set)
  ;; 3 dimensions, max 2 events per object
  (let ((events (make-array (* 6 size)))
        (id 0)
        (p 0))
    (declare (fixnum p))
    (map-kd-set (lambda (obj)
                  (dotimes (k 3)
                    (let ((min (kd-object-min obj set))
                          (max (kd-object-max obj set)))
                      (flet ((make (type)
                               (setf (aref events p)
                                     (make-event
                                      :object obj
                                      :id id
                                      :type type
                                      :e (if (= .e- type)
                                             (aref max k)
                                             (aref min k))
                                      :k k))
                               (incf p)))
                        (cond ((= (aref min k) (aref max k))
                               (make .e!))
                              (t
                               (make .e+)
                               (make .e-))))))
                  (incf id))
                set)
    (sort (sb-kernel:%shrink-vector events p) #'event<)))

(defconstant +left-only+  #b001)
(defconstant +right-only+ #b010)
(defconstant +counted+    #b100)

(defun split-events (size events e k side)
  (declare (simple-vector events)
           (fixnum size k)
           (single-float e))
  (let ((info (make-array size :element-type '(unsigned-byte 3))))
    (flet ((classify (event class)
             (setf (aref info (event-id event)) class)))
      ;; Sweep 1: Classify along K
      (dotimes (i (length events))
        (let ((event (aref events i)))
          (when (= k (event-k event))
            (let ((type (event-type event))
                  (ee (event-e event)))
              (cond ((= .e- type)
                     (when (<= ee e) (classify event +left-only+)))
                    ((= .e+ type)
                     (when (>= ee e) (classify event +right-only+)))
                    ;; The rest are for .e! types.
                    ((or (< ee e) (and (= ee e) (eq :left side)))
                     (classify event +left-only+))
                    ((or (> ee e) (and (= ee e) (eq :right side)))
                     (classify event +right-only+)))))))
      ;; Sweep 2: split into left and right -- including other Ks
      (let ((left-list (make-array (length events)))
            (right-list (make-array (length events)))
            (left 0) (right 0) (pl 0) (pr 0))
        (declare (fixnum left right pl pr))
        (dotimes (i (length events))
          (let* ((event (aref events i))
                 (mask (aref info (event-id event))))
            (macrolet ((handle-event (&key left-side right-side)
                         `(progn
                            ,@(when left-side
                                    `((setf (aref left-list (1- (incf pl))) event)))
                            ,@(when right-side
                                    `((setf (aref right-list (1- (incf pr))) event)))
                            (unless (logtest mask +counted+)
                              ,@(when left-side `((incf left)))
                              ,@(when right-side `((incf right)))
                              (classify event (logior +counted+ mask))))))
              (cond ((logtest mask +left-only+)
                     (handle-event :left-side t))
                    ((logtest mask +right-only+)
                     (handle-event :right-side t))
                    (t
                     (handle-event :left-side t :right-side t))))))
        (sb-kernel:%shrink-vector left-list pl)
        (sb-kernel:%shrink-vector right-list pr)
        (values left-list right-list left right)))))

(defun find-plane (n events min max)
  (declare (simple-vector events))
  (let* ((nl (make-array 3 :element-type 'fixnum))
         (np (make-array 3 :element-type 'fixnum))
         (nr (make-array 3 :element-type 'fixnum :initial-contents (list n n n)))
         (n-events (length events))
         (best-side nil)
         (best-cost #.sb-ext:single-float-positive-infinity)
         (best-e #.sb-ext:single-float-positive-infinity)
         (best-k 0)
         (best-lc 0)
         (best-rc 0))
    (declare (dynamic-extent nl nr np)
             (single-float best-cost best-e)
             (type (integer 0 2) best-k))
    (loop with i fixnum = 0
          while (< i n-events)
          do (let* ((event (aref events i))
                    (e (event-e event))
                    (k (event-k event))
                    (p+ 0)
                    (p- 0)
                    (p! 0))
               (declare (fixnum p+ p- p!))
               (flet ((event-ok (i type)
                        (and (< i n-events)
                             (= k (event-k (aref events i)))
                             (= e (event-e (aref events i)))
                             (= type (event-type (aref events i))))))
                 (loop while (event-ok i .e-)
                       do (incf p-)
                          (incf i))
                 (loop while (event-ok i .e!)
                       do (incf p!)
                          (incf i))
                 (loop while (event-ok i .e+)
                       do (incf p+)
                          (incf i)))
               (setf (aref np k) p!)
               (decf (aref nr k) p!)
               (decf (aref nr k) p-)
               (multiple-value-bind (cost side lc rc)
                   (surface-area-heuristic min max e k (aref nl k) (aref nr k) (aref np k))
                 (declare (single-float cost))
                 (when (< cost best-cost)
                   (setf best-cost cost
                         best-e e
                         best-k k
                         best-side side
                         best-lc lc
                         best-rc rc)))
               (incf (aref nl k) p+)
               (incf (aref nl k) p!)
               (setf (aref np k) 0)))
    (values best-e best-k best-side best-cost best-lc best-rc)))

(defun surface-area (min max)
  (declare (type vec min max))
  (let ((x (- (aref max 0) (aref min 0)))
        (y (- (aref max 1) (aref min 1)))
        (z (- (aref max 2) (aref min 2))))
    (+ (* x y) (* x z) (* y z))))

(defun split-voxel (min max e k)
  (declare (vec min max) (single-float e))
  (let ((l-max (copy-vec max))
        (r-min (copy-vec min)))
    (setf (aref l-max k) e
          (aref r-min k) e)
    (values min l-max r-min max)))

(defun surface-area-heuristic (min max e k nl nr np)
  (multiple-value-bind (l-min l-max r-min r-max) (split-voxel min max e k)
    (let* ((area (surface-area min max))
           (pl (/ (surface-area l-min l-max) area))
           (pr (/ (surface-area r-min r-max) area))
           (c.p->l (split-cost pl pr (+ nl np) nr))
           (c.p->r (split-cost pl pr nl (+ nr np))))
      (if (and (< c.p->l c.p->r) (< pl 1.0))
          (progn
            (when (and (or (= 0 nl) (plusp np)) (= 1.0 pl))
              (break "oops1 ~S, ~S" c.p->l c.p->r))
            (values c.p->l :left (+ nl np) nr))
          (progn
            (when (and (or (= 0 nr) (plusp np)) (= 1.0 pr))
              (break "oops2 ~S, ~S" c.p->l c.p->r))
            (values c.p->r :right nl (+ nr np)))))))

(defun split-cost (pl pr nl nr)
  (if (or (and (= 1.0 pl) (= 0 nr))
          (and (= 1.0 pr) (= 0 nl)))
      #.sb-ext:single-float-positive-infinity
      (* (if (or (= 0 nl) (= 0 nr))
             0.8
             1.0)
         (+ *kd-traversal-cost*
            (* *intersection-cost* (+ (* pl nl) (* pr nr)))))))
